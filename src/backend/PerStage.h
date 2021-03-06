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

#ifndef BACKEND_PERSTAGE_H_
#define BACKEND_PERSTAGE_H_

#include "common/Assert.h"
#include "common/BitSetIterator.h"
#include "common/Constants.h"

#include "nxt/nxtcpp.h"

#include <array>

namespace backend {

    static_assert(static_cast<uint32_t>(nxt::ShaderStage::Vertex) < kNumStages, "");
    static_assert(static_cast<uint32_t>(nxt::ShaderStage::Fragment) < kNumStages, "");
    static_assert(static_cast<uint32_t>(nxt::ShaderStage::Compute) < kNumStages, "");

    static_assert(static_cast<uint32_t>(nxt::ShaderStageBit::Vertex) == (1 << static_cast<uint32_t>(nxt::ShaderStage::Vertex)), "");
    static_assert(static_cast<uint32_t>(nxt::ShaderStageBit::Fragment) == (1 << static_cast<uint32_t>(nxt::ShaderStage::Fragment)), "");
    static_assert(static_cast<uint32_t>(nxt::ShaderStageBit::Compute) == (1 << static_cast<uint32_t>(nxt::ShaderStage::Compute)), "");

    BitSetIterator<kNumStages, nxt::ShaderStage> IterateStages(nxt::ShaderStageBit stages);
    nxt::ShaderStageBit StageBit(nxt::ShaderStage stage);

    static constexpr nxt::ShaderStageBit kAllStages = static_cast<nxt::ShaderStageBit>((1 << kNumStages) - 1);

    template<typename T>
    class PerStage {
        public:
            T& operator[](nxt::ShaderStage stage) {
                NXT_ASSERT(static_cast<uint32_t>(stage) < kNumStages);
                return data[static_cast<uint32_t>(stage)];
            }
            const T& operator[](nxt::ShaderStage stage) const {
                NXT_ASSERT(static_cast<uint32_t>(stage) < kNumStages);
                return data[static_cast<uint32_t>(stage)];
            }

            T& operator[](nxt::ShaderStageBit stageBit) {
                uint32_t bit = static_cast<uint32_t>(stageBit);
                NXT_ASSERT(bit != 0 && IsPowerOfTwo(bit) && bit <= (1 << kNumStages));
                return data[Log2(bit)];
            }
            const T& operator[](nxt::ShaderStageBit stageBit) const {
                uint32_t bit = static_cast<uint32_t>(stageBit);
                NXT_ASSERT(bit != 0 && IsPowerOfTwo(bit) && bit <= (1 << kNumStages));
                return data[Log2(bit)];
            }

        private:
            std::array<T, kNumStages> data;
    };

}

#endif // BACKEND_PERSTAGE_H_
