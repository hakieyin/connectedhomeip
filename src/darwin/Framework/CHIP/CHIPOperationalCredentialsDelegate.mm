/**
 *
 *    Copyright (c) 2021-2022 Project CHIP Authors
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

#include <algorithm>

#import "CHIPOperationalCredentialsDelegate.h"

#import <Security/Security.h>

#include <Security/SecKey.h>

#import "CHIPLogging.h"

#include <credentials/CHIPCert.h>
#include <crypto/CHIPCryptoPAL.h>
#include <lib/core/CHIPTLV.h>
#include <lib/core/Optional.h>
#include <lib/support/PersistentStorageMacros.h>
#include <lib/support/SafeInt.h>
#include <lib/support/TimeUtils.h>

constexpr const char kOperationalCredentialsRootCertificateStorage[] = "MatterCARootCert";

using namespace chip;
using namespace TLV;
using namespace Credentials;
using namespace Crypto;

static BOOL isRunningTests(void)
{
    NSDictionary * environment = [[NSProcessInfo processInfo] environment];
    return (environment[@"XCTestConfigurationFilePath"] != nil);
}

CHIP_ERROR CHIPOperationalCredentialsDelegate::init(CHIPPersistentStorageDelegateBridge * storage, ChipP256KeypairPtr nocSigner)
{
    if (storage == nil) {
        return CHIP_ERROR_INVALID_ARGUMENT;
    }

    CHIP_ERROR err = CHIP_NO_ERROR;
    mStorage = storage;

    if (!nocSigner) {
        CHIP_LOG_ERROR("CHIPOperationalCredentialsDelegate: No NOC Signer provided, using self managed keys");

        mIssuerKey.reset(new chip::Crypto::P256Keypair());
        err = LoadKeysFromKeyChain();

        if (err != CHIP_NO_ERROR) {
            // Generate keys if keys could not be loaded
            err = GenerateKeys();
        }
    } else {
        mIssuerKey = std::move(nocSigner);
    }

    if (err == CHIP_NO_ERROR) {
        // If keys were loaded, or generated, let's get the certificate issuer ID

        // TODO - enable generating a random issuer ID and saving it in persistent storage
        // err = SetIssuerID(storage);
    }

    CHIP_LOG_ERROR("CHIPOperationalCredentialsDelegate::init returning %s", chip::ErrorStr(err));
    return err;
}

CHIP_ERROR CHIPOperationalCredentialsDelegate::SetIssuerID(CHIPPersistentStorageDelegateBridge * storage)
{
    static const char * const CHIP_COMMISSIONER_CA_ISSUER_ID = "com.zigbee.chip.commissioner.ca.issuer.id";
    if (storage == nil) {
        return CHIP_ERROR_INVALID_ARGUMENT;
    }

    uint16_t issuerIdLen = sizeof(mIssuerId);
    if (CHIP_NO_ERROR != storage->SyncGetKeyValue(CHIP_COMMISSIONER_CA_ISSUER_ID, &mIssuerId, issuerIdLen)) {
        mIssuerId = arc4random();
        mIssuerId = mIssuerId << 32 | arc4random();
        CHIP_LOG_ERROR("Assigned %llx certificate issuer ID to the commissioner", mIssuerId);
        storage->SyncSetKeyValue(CHIP_COMMISSIONER_CA_ISSUER_ID, &mIssuerId, sizeof(mIssuerId));
    } else {
        CHIP_LOG_ERROR("Found %llx certificate issuer ID for the commissioner", mIssuerId);
    }

    return CHIP_NO_ERROR;
}

CHIP_ERROR CHIPOperationalCredentialsDelegate::LoadKeysFromKeyChain()
{
    const NSDictionary * query = @{
        (id) kSecClass : (id) kSecClassGenericPassword,
        (id) kSecAttrService : kCHIPCAKeyChainLabel,
        (id) kSecAttrSynchronizable : @YES,
        (id) kSecReturnData : @YES,
    };

    CFDataRef keyDataRef;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef) query, (CFTypeRef *) &keyDataRef);
    if (status == errSecItemNotFound || keyDataRef == nil) {
        CHIP_LOG_ERROR("Did not find self managed keys in the keychain");
        return CHIP_ERROR_KEY_NOT_FOUND;
    }

    CHIP_LOG_ERROR("Found an existing self managed keypair in the keychain");
    NSData * keyData = CFBridgingRelease(keyDataRef);

    NSData * keypairData = [[NSData alloc] initWithBase64EncodedData:keyData options:0];

    chip::Crypto::P256SerializedKeypair serialized;
    if ([keypairData length] != serialized.Capacity()) {
        NSLog(@"Keypair length %zu does not match expected length %zu", [keypairData length], serialized.Capacity());
        return CHIP_ERROR_INTERNAL;
    }

    std::memmove((uint8_t *) serialized, [keypairData bytes], [keypairData length]);
    serialized.SetLength([keypairData length]);

    CHIP_LOG_ERROR("Deserializing the key");
    return mIssuerKey->Deserialize(serialized);
}

CHIP_ERROR CHIPOperationalCredentialsDelegate::GenerateKeys()
{
    CHIP_LOG_ERROR("Generating self managed keys for the CA");
    CHIP_ERROR errorCode = mIssuerKey->Initialize();
    if (errorCode != CHIP_NO_ERROR) {
        return errorCode;
    }

    chip::Crypto::P256SerializedKeypair serializedKey;
    errorCode = mIssuerKey->Serialize(serializedKey);

    NSData * keypairData = [NSData dataWithBytes:serializedKey.Bytes() length:serializedKey.Length()];

    const NSDictionary * addParams = @{
        (id) kSecClass : (id) kSecClassGenericPassword,
        (id) kSecAttrService : kCHIPCAKeyChainLabel,
        (id) kSecAttrSynchronizable : @YES,
        (id) kSecValueData : [keypairData base64EncodedDataWithOptions:0],
    };

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef) addParams, NULL);
    // TODO: Enable SecItemAdd for Darwin unit tests
    if (status != errSecSuccess && !isRunningTests()) {
        NSLog(@"Failed in storing key : %d", status);
        return CHIP_ERROR_INTERNAL;
    }

    NSLog(@"Stored the keys");
    mGenerateRootCert = true;
    return CHIP_NO_ERROR;
}

CHIP_ERROR CHIPOperationalCredentialsDelegate::DeleteKeys()
{
    CHIP_LOG_ERROR("Deleting self managed CA keys");
    OSStatus status = noErr;

    const NSDictionary * deleteParams = @{
        (id) kSecClass : (id) kSecClassGenericPassword,
        (id) kSecAttrService : kCHIPCAKeyChainLabel,
        (id) kSecAttrSynchronizable : @YES,
    };

    status = SecItemDelete((__bridge CFDictionaryRef) deleteParams);
    if (status != errSecSuccess) {
        NSLog(@"Failed in deleting key : %d", status);
        return CHIP_ERROR_INTERNAL;
    }

    NSLog(@"Deleted the key");
    return CHIP_NO_ERROR;
}

CHIP_ERROR CHIPOperationalCredentialsDelegate::GenerateNOCChainAfterValidation(NodeId nodeId, FabricId fabricId,
    const chip::CATValues & cats, const Crypto::P256PublicKey & pubkey, MutableByteSpan & rcac, MutableByteSpan & icac,
    MutableByteSpan & noc)
{
    uint32_t validityStart, validityEnd;

    if (!ToChipEpochTime(0, validityStart)) {
        NSLog(@"Failed in computing certificate validity start date");
        return CHIP_ERROR_INTERNAL;
    }

    if (!ToChipEpochTime(kCertificateValiditySecs, validityEnd)) {
        NSLog(@"Failed in computing certificate validity end date");
        return CHIP_ERROR_INTERNAL;
    }

    ChipDN rcac_dn;
    if (!mGenerateRootCert) {
        uint16_t rcacBufLen = static_cast<uint16_t>(std::min(rcac.size(), static_cast<size_t>(UINT16_MAX)));
        PERSISTENT_KEY_OP(fabricId, kOperationalCredentialsRootCertificateStorage, key,
            ReturnErrorOnFailure(mStorage->SyncGetKeyValue(key, rcac.data(), rcacBufLen)));
        rcac.reduce_size(rcacBufLen);
        ReturnErrorOnFailure(ExtractSubjectDNFromX509Cert(rcac, rcac_dn));
    } else {
        ReturnErrorOnFailure(rcac_dn.AddAttribute(chip::ASN1::kOID_AttributeType_ChipRootId, mIssuerId));
        ReturnErrorOnFailure(rcac_dn.AddAttribute(chip::ASN1::kOID_AttributeType_ChipFabricId, fabricId));

        NSLog(@"Generating RCAC");
        X509CertRequestParams rcac_request = { 0, validityStart, validityEnd, rcac_dn, rcac_dn };
        ReturnErrorOnFailure(NewRootX509Cert(rcac_request, *mIssuerKey, rcac));

        VerifyOrReturnError(CanCastTo<uint16_t>(rcac.size()), CHIP_ERROR_INTERNAL);
        PERSISTENT_KEY_OP(fabricId, kOperationalCredentialsRootCertificateStorage, key,
            ReturnErrorOnFailure(mStorage->SyncSetKeyValue(key, rcac.data(), static_cast<uint16_t>(rcac.size()))));

        mGenerateRootCert = false;
    }

    icac.reduce_size(0);

    ChipDN noc_dn;
    ReturnErrorOnFailure(noc_dn.AddAttribute(chip::ASN1::kOID_AttributeType_ChipFabricId, fabricId));
    ReturnErrorOnFailure(noc_dn.AddAttribute(chip::ASN1::kOID_AttributeType_ChipNodeId, nodeId));
    ReturnErrorOnFailure(noc_dn.AddCATs(cats));

    X509CertRequestParams noc_request = { 1, validityStart, validityEnd, noc_dn, rcac_dn };
    return NewNodeOperationalX509Cert(noc_request, pubkey, *mIssuerKey, noc);
}

CHIP_ERROR CHIPOperationalCredentialsDelegate::GenerateNOCChain(const chip::ByteSpan & csrElements,
    const chip::ByteSpan & attestationSignature, const chip::ByteSpan & DAC, const chip::ByteSpan & PAI, const chip::ByteSpan & PAA,
    chip::Callback::Callback<chip::Controller::OnNOCChainGeneration> * onCompletion)
{
    chip::NodeId assignedId;
    if (mNodeIdRequested) {
        assignedId = mNextRequestedNodeId;
        mNodeIdRequested = false;
    } else {
        if (mDeviceBeingPaired == chip::kUndefinedNodeId) {
            return CHIP_ERROR_INCORRECT_STATE;
        }
        assignedId = mDeviceBeingPaired;
    }

    TLVReader reader;
    reader.Init(csrElements);

    if (reader.GetType() == kTLVType_NotSpecified) {
        ReturnErrorOnFailure(reader.Next());
    }

    VerifyOrReturnError(reader.GetType() == kTLVType_Structure, CHIP_ERROR_WRONG_TLV_TYPE);
    VerifyOrReturnError(reader.GetTag() == AnonymousTag(), CHIP_ERROR_UNEXPECTED_TLV_ELEMENT);

    TLVType containerType;
    ReturnErrorOnFailure(reader.EnterContainer(containerType));
    ReturnErrorOnFailure(reader.Next(kTLVType_ByteString, TLV::ContextTag(1)));

    ByteSpan csr(reader.GetReadPoint(), reader.GetLength());
    reader.ExitContainer(containerType);

    chip::Crypto::P256PublicKey pubkey;
    ReturnErrorOnFailure(chip::Crypto::VerifyCertificateSigningRequest(csr.data(), csr.size(), pubkey));

    NSMutableData * nocBuffer = [[NSMutableData alloc] initWithLength:chip::Controller::kMaxCHIPDERCertLength];
    MutableByteSpan noc((uint8_t *) [nocBuffer mutableBytes], chip::Controller::kMaxCHIPDERCertLength);

    NSMutableData * rcacBuffer = [[NSMutableData alloc] initWithLength:chip::Controller::kMaxCHIPDERCertLength];
    MutableByteSpan rcac((uint8_t *) [rcacBuffer mutableBytes], chip::Controller::kMaxCHIPDERCertLength);

    MutableByteSpan icac;

    ReturnErrorOnFailure(GenerateNOCChainAfterValidation(assignedId, mNextFabricId, chip::kUndefinedCATs, pubkey, rcac, icac, noc));

    onCompletion->mCall(onCompletion->mContext, CHIP_NO_ERROR, noc, icac, rcac, Optional<AesCcm128KeySpan>(), Optional<NodeId>());

    return CHIP_NO_ERROR;
}

bool CHIPOperationalCredentialsDelegate::ToChipEpochTime(uint32_t offset, uint32_t & epoch)
{
    NSDate * date = [NSDate dateWithTimeIntervalSinceNow:offset];
    unsigned units = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute
        | NSCalendarUnitSecond;
    NSCalendar * calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents * components = [calendar components:units fromDate:date];

    uint16_t year = static_cast<uint16_t>([components year]);
    uint8_t month = static_cast<uint8_t>([components month]);
    uint8_t day = static_cast<uint8_t>([components day]);
    uint8_t hour = static_cast<uint8_t>([components hour]);
    uint8_t minute = static_cast<uint8_t>([components minute]);
    uint8_t second = static_cast<uint8_t>([components second]);
    return chip::CalendarToChipEpochTime(year, month, day, hour, minute, second, epoch);
}
