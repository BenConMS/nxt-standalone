// Copyright 2017 The NXT Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "backend/metal/CommandBufferMTL.h"

#include "backend/Commands.h"
#include "backend/metal/BufferMTL.h"
#include "backend/metal/ComputePipelineMTL.h"
#include "backend/metal/DepthStencilStateMTL.h"
#include "backend/metal/InputStateMTL.h"
#include "backend/metal/MetalBackend.h"
#include "backend/metal/PipelineLayoutMTL.h"
#include "backend/metal/RenderPipelineMTL.h"
#include "backend/metal/SamplerMTL.h"
#include "backend/metal/TextureMTL.h"

namespace backend {
namespace metal {

    namespace {
        MTLIndexType IndexFormatType(nxt::IndexFormat format) {
            switch (format) {
                case nxt::IndexFormat::Uint16:
                    return MTLIndexTypeUInt16;
                case nxt::IndexFormat::Uint32:
                    return MTLIndexTypeUInt32;
            }
        }

        struct CurrentEncoders {
            Device* device;

            id<MTLBlitCommandEncoder> blit = nil;
            id<MTLComputeCommandEncoder> compute = nil;
            id<MTLRenderCommandEncoder> render = nil;

            RenderPass* currentRenderPass = nullptr;
            Framebuffer* currentFramebuffer = nullptr;

            void EnsureNoBlitEncoder() {
                ASSERT(render == nil);
                ASSERT(compute == nil);
                if (blit != nil) {
                    [blit endEncoding];
                    blit = nil;
                }
            }

            void EnsureBlit(id<MTLCommandBuffer> commandBuffer) {
                ASSERT(render == nil);
                ASSERT(compute == nil);
                if (blit == nil) {
                    blit = [commandBuffer blitCommandEncoder];
                }
            }

            void BeginCompute(id<MTLCommandBuffer> commandBuffer) {
                EnsureNoBlitEncoder();
                compute = [commandBuffer computeCommandEncoder];
                // TODO(cwallez@chromium.org): does any state need to be reset?
            }

            void EndCompute() {
                ASSERT(compute != nil);
                [compute endEncoding];
                compute = nil;
            }

            void BeginSubpass(id<MTLCommandBuffer> commandBuffer, uint32_t subpass) {
                ASSERT(currentRenderPass);
                if (render != nil) {
                    [render endEncoding];
                    render = nil;
                }

                const auto& info = currentRenderPass->GetSubpassInfo(subpass);

                MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
                for (uint32_t index = 0; index < info.colorAttachments.size(); ++index) {
                    uint32_t attachment = info.colorAttachments[index];

                    auto textureView = currentFramebuffer->GetTextureView(attachment);
                    auto texture = ToBackend(textureView->GetTexture())->GetMTLTexture();
                    descriptor.colorAttachments[index].texture = texture;
                    descriptor.colorAttachments[index].loadAction = MTLLoadActionLoad;
                    descriptor.colorAttachments[index].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
                    descriptor.colorAttachments[index].storeAction = MTLStoreActionStore;
                }
                if (info.depthStencilAttachmentSet) {
                    uint32_t attachment = info.depthStencilAttachment;

                    auto textureView = currentFramebuffer->GetTextureView(attachment);
                    id<MTLTexture> texture = ToBackend(textureView->GetTexture())->GetMTLTexture();
                    nxt::TextureFormat format = textureView->GetTexture()->GetFormat();
                    if (TextureFormatHasDepth(format)) {
                        descriptor.depthAttachment.texture = texture;
                        descriptor.depthAttachment.loadAction = MTLLoadActionClear;
                        descriptor.depthAttachment.clearDepth = 1.0;
                        descriptor.depthAttachment.storeAction = MTLStoreActionStore;
                    }
                    if (TextureFormatHasStencil(format)) {
                        descriptor.stencilAttachment.texture = texture;
                        descriptor.stencilAttachment.loadAction = MTLLoadActionClear;
                        descriptor.stencilAttachment.clearStencil = 0;
                        descriptor.stencilAttachment.storeAction = MTLStoreActionStore;
                    }
                }

                render = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
                // TODO(cwallez@chromium.org): does any state need to be reset?
            }

            void EndSubpass() {
                ASSERT(render != nil);
                [render endEncoding];
                render = nil;
            }
        };
    }

    CommandBuffer::CommandBuffer(CommandBufferBuilder* builder)
        : CommandBufferBase(builder), device(ToBackend(builder->GetDevice())),
          commands(builder->AcquireCommands()) {
    }

    CommandBuffer::~CommandBuffer() {
        FreeCommands(&commands);
    }

    void CommandBuffer::FillCommands(id<MTLCommandBuffer> commandBuffer) {
        Command type;
        ComputePipeline* lastComputePipeline = nullptr;
        RenderPipeline* lastRenderPipeline = nullptr;
        id<MTLBuffer> indexBuffer = nil;
        uint32_t indexBufferOffset = 0;
        MTLIndexType indexType = MTLIndexTypeUInt32;

        CurrentEncoders encoders;
        encoders.device = device;

        PerStage<std::array<uint32_t, kMaxPushConstants>> pushConstants;

        uint32_t currentSubpass = 0;
        while (commands.NextCommandId(&type)) {
            switch (type) {
                case Command::BeginComputePass:
                    {
                        commands.NextCommand<BeginComputePassCmd>();
                        encoders.BeginCompute(commandBuffer);

                        pushConstants[nxt::ShaderStage::Compute].fill(0);
                        [encoders.compute setBytes: &pushConstants[nxt::ShaderStage::Compute]
                                            length: sizeof(uint32_t) * kMaxPushConstants
                                           atIndex: 0];
                    }
                    break;

                case Command::BeginRenderPass:
                    {
                        BeginRenderPassCmd* beginRenderPassCmd = commands.NextCommand<BeginRenderPassCmd>();
                        encoders.currentRenderPass = ToBackend(beginRenderPassCmd->renderPass.Get());
                        encoders.currentFramebuffer = ToBackend(beginRenderPassCmd->framebuffer.Get());
                        encoders.EnsureNoBlitEncoder();
                        currentSubpass = 0;
                    }
                    break;

                case Command::BeginRenderSubpass:
                    {
                        commands.NextCommand<BeginRenderSubpassCmd>();
                        encoders.BeginSubpass(commandBuffer, currentSubpass);

                        pushConstants[nxt::ShaderStage::Vertex].fill(0);
                        pushConstants[nxt::ShaderStage::Fragment].fill(0);

                        [encoders.render setVertexBytes: &pushConstants[nxt::ShaderStage::Vertex]
                                                 length: sizeof(uint32_t) * kMaxPushConstants
                                                atIndex: 0];
                        [encoders.render setFragmentBytes: &pushConstants[nxt::ShaderStage::Fragment]
                                                   length: sizeof(uint32_t) * kMaxPushConstants
                                                  atIndex: 0];
                    }
                    break;

                case Command::CopyBufferToBuffer:
                    {
                        CopyBufferToBufferCmd* copy = commands.NextCommand<CopyBufferToBufferCmd>();
                        auto& src = copy->source;
                        auto& dst = copy->destination;

                        encoders.EnsureBlit(commandBuffer);
                        [encoders.blit
                            copyFromBuffer:ToBackend(src.buffer)->GetMTLBuffer()
                            sourceOffset:src.offset
                            toBuffer:ToBackend(dst.buffer)->GetMTLBuffer()
                            destinationOffset:dst.offset
                            size:copy->size];
                    }
                    break;

                case Command::CopyBufferToTexture:
                    {
                        CopyBufferToTextureCmd* copy = commands.NextCommand<CopyBufferToTextureCmd>();
                        auto& src = copy->source;
                        auto& dst = copy->destination;
                        Buffer* buffer = ToBackend(src.buffer.Get());
                        Texture* texture = ToBackend(dst.texture.Get());

                        MTLOrigin origin;
                        origin.x = dst.x;
                        origin.y = dst.y;
                        origin.z = dst.z;

                        MTLSize size;
                        size.width = dst.width;
                        size.height = dst.height;
                        size.depth = dst.depth;

                        encoders.EnsureBlit(commandBuffer);
                        [encoders.blit
                            copyFromBuffer:buffer->GetMTLBuffer()
                            sourceOffset:src.offset
                            sourceBytesPerRow:copy->rowPitch
                            sourceBytesPerImage:(copy->rowPitch * dst.height)
                            sourceSize:size
                            toTexture:texture->GetMTLTexture()
                            destinationSlice:0
                            destinationLevel:dst.level
                            destinationOrigin:origin];
                    }
                    break;

                case Command::CopyTextureToBuffer:
                    {
                        CopyTextureToBufferCmd* copy = commands.NextCommand<CopyTextureToBufferCmd>();
                        auto& src = copy->source;
                        auto& dst = copy->destination;
                        Texture* texture = ToBackend(src.texture.Get());
                        Buffer* buffer = ToBackend(dst.buffer.Get());

                        MTLOrigin origin;
                        origin.x = src.x;
                        origin.y = src.y;
                        origin.z = src.z;

                        MTLSize size;
                        size.width = src.width;
                        size.height = src.height;
                        size.depth = src.depth;

                        encoders.EnsureBlit(commandBuffer);
                        [encoders.blit
                            copyFromTexture:texture->GetMTLTexture()
                            sourceSlice:0
                            sourceLevel:src.level
                            sourceOrigin:origin
                            sourceSize:size
                            toBuffer:buffer->GetMTLBuffer()
                            destinationOffset:dst.offset
                            destinationBytesPerRow:copy->rowPitch
                            destinationBytesPerImage:copy->rowPitch * src.height];
                    }
                    break;

                case Command::Dispatch:
                    {
                        DispatchCmd* dispatch = commands.NextCommand<DispatchCmd>();
                        ASSERT(encoders.compute);

                        [encoders.compute dispatchThreadgroups:MTLSizeMake(dispatch->x, dispatch->y, dispatch->z)
                            threadsPerThreadgroup: lastComputePipeline->GetLocalWorkGroupSize()];
                    }
                    break;

                case Command::DrawArrays:
                    {
                        DrawArraysCmd* draw = commands.NextCommand<DrawArraysCmd>();

                        ASSERT(encoders.render);
                        [encoders.render
                            drawPrimitives:lastRenderPipeline->GetMTLPrimitiveTopology()
                            vertexStart:draw->firstVertex
                            vertexCount:draw->vertexCount
                            instanceCount:draw->instanceCount
                            baseInstance:draw->firstInstance];
                    }
                    break;

                case Command::DrawElements:
                    {
                        DrawElementsCmd* draw = commands.NextCommand<DrawElementsCmd>();

                        ASSERT(encoders.render);
                        [encoders.render
                            drawIndexedPrimitives:lastRenderPipeline->GetMTLPrimitiveTopology()
                            indexCount:draw->indexCount
                            indexType:indexType
                            indexBuffer:indexBuffer
                            indexBufferOffset:indexBufferOffset
                            instanceCount:draw->instanceCount
                            baseVertex:0
                            baseInstance:draw->firstInstance];
                    }
                    break;

                case Command::EndComputePass:
                    {
                        commands.NextCommand<EndComputePassCmd>();
                        encoders.EndCompute();
                    }
                    break;

                case Command::EndRenderPass:
                    {
                        commands.NextCommand<EndRenderPassCmd>();
                    }
                    break;

                case Command::EndRenderSubpass:
                    {
                        commands.NextCommand<EndRenderSubpassCmd>();
                        encoders.EndSubpass();
                        currentSubpass += 1;
                    }
                    break;

                case Command::SetComputePipeline:
                    {
                        SetComputePipelineCmd* cmd = commands.NextCommand<SetComputePipelineCmd>();
                        lastComputePipeline = ToBackend(cmd->pipeline).Get();

                        ASSERT(encoders.compute);
                        lastComputePipeline->Encode(encoders.compute);
                    }
                    break;

                case Command::SetRenderPipeline:
                    {
                        SetRenderPipelineCmd* cmd = commands.NextCommand<SetRenderPipelineCmd>();
                        lastRenderPipeline = ToBackend(cmd->pipeline).Get();

                        ASSERT(encoders.render);
                        DepthStencilState* depthStencilState = ToBackend(lastRenderPipeline->GetDepthStencilState());
                        [encoders.render setDepthStencilState:depthStencilState->GetMTLDepthStencilState()];
                        lastRenderPipeline->Encode(encoders.render);
                    }
                    break;

                case Command::SetPushConstants:
                    {
                        SetPushConstantsCmd* cmd = commands.NextCommand<SetPushConstantsCmd>();
                        uint32_t* values = commands.NextData<uint32_t>(cmd->count);

                        for (auto stage : IterateStages(cmd->stages)) {
                            memcpy(&pushConstants[stage][cmd->offset], values, cmd->count * sizeof(uint32_t));

                            switch (stage) {
                                case nxt::ShaderStage::Compute:
                                    ASSERT(encoders.compute);
                                    [encoders.compute setBytes: &pushConstants[nxt::ShaderStage::Compute]
                                                        length: sizeof(uint32_t) * kMaxPushConstants
                                                       atIndex: 0];
                                    break;
                                case nxt::ShaderStage::Fragment:
                                    ASSERT(encoders.render);
                                    [encoders.render setFragmentBytes: &pushConstants[nxt::ShaderStage::Fragment]
                                                               length: sizeof(uint32_t) * kMaxPushConstants
                                                              atIndex: 0];
                                    break;
                                case nxt::ShaderStage::Vertex:
                                    ASSERT(encoders.render);
                                    [encoders.render setVertexBytes: &pushConstants[nxt::ShaderStage::Vertex]
                                                             length: sizeof(uint32_t) * kMaxPushConstants
                                                            atIndex: 0];
                                    break;
                                default:
                                    UNREACHABLE();
                                    break;
                            }
                        }
                    }
                    break;

                case Command::SetStencilReference:
                    {
                        SetStencilReferenceCmd* cmd = commands.NextCommand<SetStencilReferenceCmd>();

                        ASSERT(encoders.render);

                        [encoders.render setStencilReferenceValue:cmd->reference];
                    }
                    break;

                case Command::SetBindGroup:
                    {
                        SetBindGroupCmd* cmd = commands.NextCommand<SetBindGroupCmd>();
                        BindGroup* group = ToBackend(cmd->group.Get());
                        uint32_t groupIndex = cmd->index;

                        const auto& layout = group->GetLayout()->GetBindingInfo();

                        // TODO(kainino@chromium.org): Maintain buffers and offsets arrays in BindGroup so that we
                        // only have to do one setVertexBuffers and one setFragmentBuffers call here.
                        for (size_t binding = 0; binding < layout.mask.size(); ++binding) {
                            if (!layout.mask[binding]) {
                                continue;
                            }

                            auto stage = layout.visibilities[binding];
                            bool vertStage = stage & nxt::ShaderStageBit::Vertex;
                            bool fragStage = stage & nxt::ShaderStageBit::Fragment;
                            bool computeStage = stage & nxt::ShaderStageBit::Compute;
                            uint32_t vertIndex = 0;
                            uint32_t fragIndex = 0;
                            uint32_t computeIndex = 0;
                            if (vertStage) {
                                ASSERT(lastRenderPipeline != nullptr);
                                vertIndex = ToBackend(lastRenderPipeline->GetLayout())->
                                    GetBindingIndexInfo(nxt::ShaderStage::Vertex)[groupIndex][binding];
                            }
                            if (fragStage) {
                                ASSERT(lastRenderPipeline != nullptr);
                                fragIndex = ToBackend(lastRenderPipeline->GetLayout())->
                                    GetBindingIndexInfo(nxt::ShaderStage::Fragment)[groupIndex][binding];
                            }
                            if (computeStage) {
                                ASSERT(lastComputePipeline != nullptr);
                                computeIndex = ToBackend(lastComputePipeline->GetLayout())->
                                    GetBindingIndexInfo(nxt::ShaderStage::Compute)[groupIndex][binding];
                            }

                            switch (layout.types[binding]) {
                                case nxt::BindingType::UniformBuffer:
                                case nxt::BindingType::StorageBuffer:
                                    {
                                        BufferView* view = ToBackend(group->GetBindingAsBufferView(binding));
                                        auto b = ToBackend(view->GetBuffer());
                                        const id<MTLBuffer> buffer = b->GetMTLBuffer();
                                        const NSUInteger offset = view->GetOffset();
                                        if (vertStage) {
                                            [encoders.render
                                                setVertexBuffers:&buffer
                                                offsets:&offset
                                                withRange:NSMakeRange(vertIndex, 1)];
                                        }
                                        if (fragStage) {
                                            [encoders.render
                                                setFragmentBuffers:&buffer
                                                offsets:&offset
                                                withRange:NSMakeRange(fragIndex, 1)];
                                        }
                                        if (computeStage) {
                                            [encoders.compute
                                                setBuffers:&buffer
                                                offsets:&offset
                                                withRange:NSMakeRange(computeIndex, 1)];
                                        }

                                    }
                                    break;

                                case nxt::BindingType::Sampler:
                                    {
                                        auto sampler = ToBackend(group->GetBindingAsSampler(binding));
                                        if (vertStage) {
                                            [encoders.render
                                                setVertexSamplerState:sampler->GetMTLSamplerState()
                                                atIndex:vertIndex];
                                        }
                                        if (fragStage) {
                                            [encoders.render
                                                setFragmentSamplerState:sampler->GetMTLSamplerState()
                                                atIndex:fragIndex];
                                        }
                                        if (computeStage) {
                                            [encoders.compute
                                                setSamplerState:sampler->GetMTLSamplerState()
                                                atIndex:computeIndex];
                                        }
                                    }
                                    break;

                                case nxt::BindingType::SampledTexture:
                                    {
                                        auto texture = ToBackend(group->GetBindingAsTextureView(binding)->GetTexture());
                                        if (vertStage) {
                                            [encoders.render
                                                setVertexTexture:texture->GetMTLTexture()
                                                atIndex:vertIndex];
                                        }
                                        if (fragStage) {
                                            [encoders.render
                                                setFragmentTexture:texture->GetMTLTexture()
                                                atIndex:fragIndex];
                                        }
                                        if (computeStage) {
                                            [encoders.compute
                                                setTexture:texture->GetMTLTexture()
                                                atIndex:computeIndex];
                                        }
                                    }
                                    break;
                            }
                        }
                    }
                    break;

                case Command::SetIndexBuffer:
                    {
                        SetIndexBufferCmd* cmd = commands.NextCommand<SetIndexBufferCmd>();
                        auto b = ToBackend(cmd->buffer.Get());
                        indexBuffer = b->GetMTLBuffer();
                        indexBufferOffset = cmd->offset;
                        indexType = IndexFormatType(cmd->format);
                    }
                    break;

                case Command::SetVertexBuffers:
                    {
                        SetVertexBuffersCmd* cmd = commands.NextCommand<SetVertexBuffersCmd>();
                        auto buffers = commands.NextData<Ref<BufferBase>>(cmd->count);
                        auto offsets = commands.NextData<uint32_t>(cmd->count);

                        std::array<id<MTLBuffer>, kMaxVertexInputs> mtlBuffers;
                        std::array<NSUInteger, kMaxVertexInputs> mtlOffsets;

                        // Perhaps an "array of vertex buffers(+offsets?)" should be
                        // a NXT API primitive to avoid reconstructing this array?
                        for (uint32_t i = 0; i < cmd->count; ++i) {
                            Buffer* buffer = ToBackend(buffers[i].Get());
                            mtlBuffers[i] = buffer->GetMTLBuffer();
                            mtlOffsets[i] = offsets[i];
                        }

                        ASSERT(encoders.render);
                        [encoders.render
                            setVertexBuffers:mtlBuffers.data()
                            offsets:mtlOffsets.data()
                            withRange:NSMakeRange(kMaxBindingsPerGroup + cmd->startSlot, cmd->count)];
                    }
                    break;

                case Command::TransitionBufferUsage:
                    {
                        TransitionBufferUsageCmd* cmd = commands.NextCommand<TransitionBufferUsageCmd>();

                        cmd->buffer->UpdateUsageInternal(cmd->usage);
                    }
                    break;

                case Command::TransitionTextureUsage:
                    {
                        TransitionTextureUsageCmd* cmd = commands.NextCommand<TransitionTextureUsageCmd>();

                        cmd->texture->UpdateUsageInternal(cmd->usage);
                    }
                    break;
            }
        }

        encoders.EnsureNoBlitEncoder();
        ASSERT(encoders.render == nil);
        ASSERT(encoders.compute == nil);
    }

}
}
