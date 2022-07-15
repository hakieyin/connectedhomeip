/*
 *
 *    Copyright (c) 2022 Project CHIP Authors
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */
#pragma once
#include <cstdint>

#include <lib/support/Span.h>
#include <platform/CHIPDeviceConfig.h>

namespace chip {
namespace DevelopmentCerts {

extern ByteSpan kDacCert;
extern ByteSpan kDacPublicKey;
extern ByteSpan kDacPrivateKey;

#if CHIP_DEVICE_CONFIG_DEVICE_PRODUCT_ID == 0x1234
extern const uint8_t kDevelopmentDAC_Cert_FFF2_1234[492];
extern const uint8_t kDevelopmentDAC_PublicKey_FFF2_1234[65];
extern const uint8_t kDevelopmentDAC_PrivateKey_FFF2_1234[32];
#endif
} // namespace DevelopmentCerts
} // namespace chip
