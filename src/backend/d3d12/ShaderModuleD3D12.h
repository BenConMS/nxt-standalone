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

#ifndef BACKEND_D3D12_SHADERMODULED3D12_H_
#define BACKEND_D3D12_SHADERMODULED3D12_H_

#include "backend/ShaderModule.h"

namespace backend {
namespace d3d12 {

    class Device;

    class ShaderModule : public ShaderModuleBase {
        public:
            ShaderModule(Device* device, ShaderModuleBuilder* builder);

            const std::string& GetHLSLSource() const;

        private:
            Device* device;

            std::string hlslSource;
    };

}
}

#endif // BACKEND_D3D12_SHADERMODULED3D12_H_
