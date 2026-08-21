/*
 * ddj-sz-routing
 *
 * Native macOS tool that restores Serato DVS USB routing on Pioneer-style
 * mixers. The DDJ-SZ profile ships built-in. Other devices can be added as
 * JSON profiles; learn mode never guesses USB writes.
 *
 * Pioneer mixer-select protocol (from PioneerDDJSetup):
 *   SET  bmRequestType=0x40  bRequest=0x03  wIndex=0x8002  wLength=0
 *   GET  bmRequestType=0xC0  bRequest=0x00  wIndex=0x8002  wLength=6
 */

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_GET_LEN 32

typedef struct {
    uint16_t vendor;
    uint16_t product;
    io_service_t service;
} USBDeviceInfo;

typedef struct {
    IOUSBDeviceInterface650 **iokit;
    IOUSBHostDevice *host;
} USBSession;

#pragma mark - Helpers

static NSError *errorWithCode(NSErrorDomain domain, NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:domain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static uint32_t parseNumber(id value, uint32_t fallback)
{
    if ([value isKindOfClass:[NSNumber class]]) {
        return (uint32_t)[value unsignedIntValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)value lowercaseString];
        if ([text hasPrefix:@"0x"]) {
            unsigned int parsed = 0;
            [[NSScanner scannerWithString:text] scanHexInt:&parsed];
            return parsed;
        }
        return (uint32_t)[text intValue];
    }
    return fallback;
}

static NSString *hex4(uint16_t value)
{
    return [NSString stringWithFormat:@"0x%04x", value];
}

static NSString *readLine(void)
{
    char buffer[512];
    if (fgets(buffer, sizeof(buffer), stdin) == NULL) {
        return @"";
    }
    NSString *line = [[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return line ?: @"";
}

static BOOL askYes(NSString *prompt, BOOL defaultYes)
{
    printf("%s [%s]: ", prompt.UTF8String, defaultYes ? "Y/n" : "y/N");
    fflush(stdout);
    NSString *line = [readLine() lowercaseString];
    if (line.length == 0) {
        return defaultYes;
    }
    return [line hasPrefix:@"y"];
}

#pragma mark - Profiles

static NSURL *userProfileDirectory(void)
{
    NSURL *base = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                         inDomain:NSUserDomainMask
                                                appropriateForURL:nil
                                                           create:YES
                                                            error:nil];
    return [base URLByAppendingPathComponent:@"ddj-sz-routing/profiles" isDirectory:YES];
}

static NSURL *bundledProfileDirectory(void)
{
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    return [NSURL fileURLWithPath:[cwd stringByAppendingPathComponent:@"profiles"] isDirectory:YES];
}

static NSDictionary *builtinDDJSZProfile(void)
{
    return @{
        @"name": @"Pioneer DDJ-SZ",
        @"vendor_id": @"0x08e4",
        @"product_id": @"0x0191",
        @"protocol": @"pioneer_mixer_select",
        @"get": @{
            @"bmRequestType": @"0xC0",
            @"bRequest": @"0x00",
            @"wValue": @"0x0000",
            @"wIndex": @"0x8002",
            @"wLength": @6,
            @"channel_byte_offset": @1
        },
        @"set": @{
            @"bmRequestType": @"0x40",
            @"bRequest": @"0x03",
            @"wIndex": @"0x8002",
            @"wLength": @0
        },
        @"firmware": @{
            @"bmRequestType": @"0xC0",
            @"bRequest": @"0x00",
            @"wValue": @"0x0000",
            @"wIndex": @"0x8001",
            @"wLength": @2
        },
        @"slots": @[
            @{ @"id": @"CH1", @"labels": @[ @"CH1 Control Tone CD", @"Post CH1 Fader", @"Cross Fader A", @"Cross Fader B", @"MIC" ] },
            @{ @"id": @"CH2", @"labels": @[ @"CH2 Control Tone CD", @"Post CH2 Fader", @"Cross Fader A", @"Cross Fader B", @"MIC" ] },
            @{ @"id": @"CH3", @"labels": @[ @"CH3 Control Tone PHONO", @"CH3 Control Tone LINE", @"Post CH3 Fader", @"Cross Fader A", @"Cross Fader B", @"MIC" ] },
            @{ @"id": @"CH4", @"labels": @[ @"CH4 Control Tone PHONO", @"CH4 Control Tone LINE", @"Post CH4 Fader", @"Cross Fader A", @"Cross Fader B", @"MIC" ] },
            @{ @"id": @"USB 9-10", @"labels": @[ @"MIX(REC OUT)", @"Cross Fader A", @"Cross Fader B", @"MIC", @"Post CH1 Fader", @"Post CH2 Fader", @"Post CH3 Fader", @"Post CH4 Fader" ] }
        ],
        @"dvs": @[
            @{ @"slot": @"CH3", @"label": @"Control Tone PHONO", @"wValue": @"0x0303", @"expect_index": @0 },
            @{ @"slot": @"CH4", @"label": @"Control Tone PHONO", @"wValue": @"0x0403", @"expect_index": @0 }
        ]
    };
}

static NSString *profileKey(uint16_t vendor, uint16_t product)
{
    return [NSString stringWithFormat:@"%04x_%04x", vendor, product];
}

static NSDictionary *loadJSON(NSURL *url)
{
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static void addProfilesFromDirectory(NSMutableDictionary *byKey, NSURL *directory)
{
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil];
    for (NSURL *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"json"]) {
            continue;
        }
        NSDictionary *profile = loadJSON(file);
        if (!profile) {
            continue;
        }
        uint16_t vendor = (uint16_t)parseNumber(profile[@"vendor_id"], 0);
        uint16_t product = (uint16_t)parseNumber(profile[@"product_id"], 0);
        if (vendor == 0 || product == 0) {
            continue;
        }
        byKey[profileKey(vendor, product)] = profile;
    }
}

static NSDictionary *allProfiles(void)
{
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
    NSDictionary *builtin = builtinDDJSZProfile();
    byKey[profileKey((uint16_t)parseNumber(builtin[@"vendor_id"], 0),
                     (uint16_t)parseNumber(builtin[@"product_id"], 0))] = builtin;
    addProfilesFromDirectory(byKey, bundledProfileDirectory());
    addProfilesFromDirectory(byKey, userProfileDirectory());
    return byKey;
}

static BOOL saveProfile(NSDictionary *profile, NSError **outError)
{
    uint16_t vendor = (uint16_t)parseNumber(profile[@"vendor_id"], 0);
    uint16_t product = (uint16_t)parseNumber(profile[@"product_id"], 0);
    NSURL *directory = userProfileDirectory();
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:outError]) {
        return NO;
    }
    NSURL *url = [directory URLByAppendingPathComponent:
                  [NSString stringWithFormat:@"%@.json", profileKey(vendor, product)]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:profile
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:outError];
    if (!data) {
        return NO;
    }
    if (![data writeToURL:url options:NSDataWritingAtomic error:outError]) {
        return NO;
    }
    printf("Saved profile: %s\n", url.path.UTF8String);
    return YES;
}

static NSInteger slotIndexNamed(NSDictionary *profile, NSString *name)
{
    NSArray *slots = profile[@"slots"];
    for (NSInteger i = 0; i < (NSInteger)slots.count; i++) {
        if ([slots[i][@"id"] isEqualToString:name]) {
            return i;
        }
    }
    return NSNotFound;
}

#pragma mark - USB

static NSArray<NSDictionary *> *listUSBDevices(void)
{
    NSMutableArray *result = [NSMutableArray array];
    CFDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return result;
    }

    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        int vendor = 0;
        int product = 0;
        CFNumberRef vendorRef = IORegistryEntryCreateCFProperty(service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        CFNumberRef productRef = IORegistryEntryCreateCFProperty(service, CFSTR("idProduct"), kCFAllocatorDefault, 0);
        CFStringRef nameRef = IORegistryEntryCreateCFProperty(service, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
        if (!nameRef) {
            nameRef = IORegistryEntryCreateCFProperty(service, CFSTR("kUSBProductString"), kCFAllocatorDefault, 0);
        }
        if (vendorRef) {
            CFNumberGetValue(vendorRef, kCFNumberIntType, &vendor);
            CFRelease(vendorRef);
        }
        if (productRef) {
            CFNumberGetValue(productRef, kCFNumberIntType, &product);
            CFRelease(productRef);
        }
        NSString *name = nameRef ? [(__bridge NSString *)nameRef copy] : @"USB device";
        if (nameRef) {
            CFRelease(nameRef);
        }
        [result addObject:@{
            @"vendor": @(vendor),
            @"product": @(product),
            @"name": name ?: @"USB device",
            @"service": @((NSUInteger)service)
        }];
    }
    IOObjectRelease(iterator);
    return result;
}

static io_service_t serviceFromDevice(NSDictionary *device)
{
    return (io_service_t)[device[@"service"] unsignedIntegerValue];
}

static void releaseDeviceList(NSArray<NSDictionary *> *devices)
{
    for (NSDictionary *device in devices) {
        io_service_t service = serviceFromDevice(device);
        if (service) {
            IOObjectRelease(service);
        }
    }
}

static io_service_t matchingService(uint16_t vendor, uint16_t product)
{
    CFMutableDictionaryRef matching =
        [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(vendor)
                                                    productID:@(product)
                                                    bcdDevice:nil
                                                  deviceClass:nil
                                               deviceSubclass:nil
                                               deviceProtocol:nil
                                                        speed:nil
                                               productIDArray:nil];
    return IOServiceGetMatchingService(kIOMainPortDefault, matching);
}

static BOOL findPreferredDevice(USBDeviceInfo *outInfo, NSDictionary **outProfile)
{
    NSDictionary *profiles = allProfiles();
    USBDeviceInfo found = { 0, 0, 0 };
    NSDictionary *foundProfile = nil;
    NSInteger matches = 0;

    for (NSString *key in profiles) {
        NSDictionary *profile = profiles[key];
        uint16_t vendor = (uint16_t)parseNumber(profile[@"vendor_id"], 0);
        uint16_t product = (uint16_t)parseNumber(profile[@"product_id"], 0);
        io_service_t service = matchingService(vendor, product);
        if (!service) {
            continue;
        }
        matches++;
        if (found.service) {
            IOObjectRelease(found.service);
        }
        found.vendor = vendor;
        found.product = product;
        found.service = service;
        foundProfile = profile;
    }

    if (matches == 0) {
        if (outProfile) {
            *outProfile = nil;
        }
        return NO;
    }
    *outInfo = found;
    if (outProfile) {
        *outProfile = foundProfile;
    }
    return YES;
}

static void usbClose(USBSession *session)
{
    if (session->host) {
        [session->host destroy];
        session->host = nil;
    }
    if (session->iokit) {
        (*session->iokit)->USBDeviceClose(session->iokit);
        (*session->iokit)->Release(session->iokit);
        session->iokit = NULL;
    }
}

static BOOL openWithIOKit(io_service_t service, USBSession *session, NSError **outError)
{
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service,
                                                         kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID,
                                                         &plugin,
                                                         &score);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        if (outError) {
            *outError = errorWithCode(NSMachErrorDomain, kr,
                                      [NSString stringWithFormat:@"IOCreatePlugInInterfaceForService failed (0x%08x)", kr]);
        }
        return NO;
    }

    IOUSBDeviceInterface650 **device = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin,
                                           CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650),
                                           (LPVOID *)&device);
    (*plugin)->Release(plugin);
    if (hr != S_OK || device == NULL) {
        if (outError) {
            *outError = errorWithCode(NSOSStatusErrorDomain, hr, @"IOUSBDeviceInterface650 is unavailable");
        }
        return NO;
    }

    IOReturn ret = (*device)->USBDeviceOpen(device);
    if (ret != kIOReturnSuccess && ret != kIOReturnExclusiveAccess) {
        (*device)->Release(device);
        if (outError) {
            *outError = errorWithCode(NSMachErrorDomain, ret,
                                      [NSString stringWithFormat:@"USBDeviceOpen failed (0x%08x)", ret]);
        }
        return NO;
    }
    session->iokit = device;
    return YES;
}

static BOOL openWithHost(io_service_t service, USBSession *session, NSError **outError)
{
    NSError *error = nil;
    IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:service
                                                                 options:IOUSBHostObjectInitOptionsNone
                                                                   queue:nil
                                                                   error:&error
                                                         interestHandler:nil];
    if (!device) {
        if (outError) {
            *outError = error;
        }
        return NO;
    }
    session->host = device;
    return YES;
}

static BOOL usbOpenService(io_service_t service, USBSession *session, NSError **outError)
{
    session->iokit = NULL;
    session->host = nil;

    NSError *iokitError = nil;
    if (openWithIOKit(service, session, &iokitError)) {
        return YES;
    }
    NSError *hostError = nil;
    if (openWithHost(service, session, &hostError)) {
        return YES;
    }
    if (outError) {
        NSString *detail = [NSString stringWithFormat:@"%@ (%@)",
                            hostError.localizedDescription ?: @"IOUSBHost failed",
                            iokitError.localizedDescription ?: @"IOUSBLib failed"];
        *outError = errorWithCode(NSPOSIXErrorDomain, EIO, detail);
    }
    return NO;
}

static BOOL usbControl(USBSession *session,
                       uint8_t bmRequestType,
                       uint8_t bRequest,
                       uint16_t wValue,
                       uint16_t wIndex,
                       uint16_t wLength,
                       void *data,
                       NSError **outError)
{
    if (session->iokit) {
        IOUSBDevRequest request;
        memset(&request, 0, sizeof(request));
        request.bmRequestType = bmRequestType;
        request.bRequest = bRequest;
        request.wValue = wValue;
        request.wIndex = wIndex;
        request.wLength = wLength;
        request.pData = data;
        IOReturn ret = (*session->iokit)->DeviceRequest(session->iokit, &request);
        if (ret != kIOReturnSuccess) {
            if (outError) {
                *outError = errorWithCode(NSMachErrorDomain, ret,
                                          [NSString stringWithFormat:@"USB control transfer failed (0x%08x)", ret]);
            }
            return NO;
        }
        return YES;
    }

    if (session->host) {
        IOUSBDeviceRequest request;
        memset(&request, 0, sizeof(request));
        request.bmRequestType = bmRequestType;
        request.bRequest = bRequest;
        request.wValue = OSSwapHostToLittleInt16(wValue);
        request.wIndex = OSSwapHostToLittleInt16(wIndex);
        request.wLength = OSSwapHostToLittleInt16(wLength);
        NSMutableData *buffer = nil;
        if (wLength > 0 && data != NULL) {
            buffer = [NSMutableData dataWithBytes:data length:wLength];
        }
        NSUInteger transferred = 0;
        NSError *error = nil;
        if (![session->host sendDeviceRequest:request
                                         data:buffer
                             bytesTransferred:&transferred
                                        error:&error]) {
            if (outError) {
                *outError = error;
            }
            return NO;
        }
        if (buffer && data) {
            memcpy(data, buffer.bytes, MIN((NSUInteger)wLength, buffer.length));
        }
        return YES;
    }

    if (outError) {
        *outError = errorWithCode(NSPOSIXErrorDomain, ENXIO, @"USB session is closed");
    }
    return NO;
}

static BOOL profileGet(USBSession *session, NSDictionary *profile, uint8_t *out, uint16_t *outLen, NSError **error)
{
    NSDictionary *get = profile[@"get"];
    uint16_t length = (uint16_t)parseNumber(get[@"wLength"], 6);
    if (length == 0 || length > MAX_GET_LEN) {
        if (error) {
            *error = errorWithCode(NSPOSIXErrorDomain, EINVAL, @"Invalid GET wLength in profile");
        }
        return NO;
    }
    memset(out, 0, MAX_GET_LEN);
    BOOL ok = usbControl(session,
                         (uint8_t)parseNumber(get[@"bmRequestType"], 0xC0),
                         (uint8_t)parseNumber(get[@"bRequest"], 0x00),
                         (uint16_t)parseNumber(get[@"wValue"], 0),
                         (uint16_t)parseNumber(get[@"wIndex"], 0x8002),
                         length,
                         out,
                         error);
    if (ok && outLen) {
        *outLen = length;
    }
    return ok;
}

static BOOL profileSet(USBSession *session, NSDictionary *profile, uint16_t wValue, NSError **error)
{
    NSDictionary *set = profile[@"set"];
    return usbControl(session,
                      (uint8_t)parseNumber(set[@"bmRequestType"], 0x40),
                      (uint8_t)parseNumber(set[@"bRequest"], 0x03),
                      wValue,
                      (uint16_t)parseNumber(set[@"wIndex"], 0x8002),
                      (uint16_t)parseNumber(set[@"wLength"], 0),
                      NULL,
                      error);
}

static NSArray *dvsWrites(NSDictionary *profile)
{
    NSMutableArray *writes = [NSMutableArray array];
    for (NSDictionary *entry in profile[@"dvs"]) {
        if (parseNumber(entry[@"wValue"], 0) != 0) {
            [writes addObject:entry];
        }
    }
    return writes;
}

static void printRouting(NSDictionary *profile, const uint8_t *buffer, uint16_t length)
{
    NSInteger offset = (NSInteger)parseNumber(profile[@"get"][@"channel_byte_offset"], 1);
    NSArray *slots = profile[@"slots"];
    NSInteger count = slots.count > 0 ? (NSInteger)slots.count : (NSInteger)length - offset;

    printf("USB input routing:\n");
    for (NSInteger i = 0; i < count; i++) {
        NSInteger byteIndex = offset + i;
        if (byteIndex < 0 || byteIndex >= length) {
            break;
        }
        uint8_t index = buffer[byteIndex];
        NSString *slotName = @"CH";
        NSString *label = [NSString stringWithFormat:@"index %u", index];
        if (i < (NSInteger)slots.count) {
            NSDictionary *slot = slots[i];
            slotName = slot[@"id"] ?: slotName;
            NSArray *labels = slot[@"labels"];
            if (index < labels.count) {
                label = labels[index];
            }
        }

        const char *mark = "";
        for (NSDictionary *dvs in profile[@"dvs"]) {
            if ([dvs[@"slot"] isEqualToString:slotName] &&
                parseNumber(dvs[@"expect_index"], 255) == index) {
                mark = "  [DVS]";
                break;
            }
        }
        printf("  %-10s  %s%s\n", slotName.UTF8String, label.UTF8String, mark);
    }
}

static void printDevice(USBDeviceInfo info, NSDictionary *profile)
{
    NSString *title = [profile[@"name"] isKindOfClass:[NSString class]] ? profile[@"name"] : @"USB device";
    printf("%s  VID %s  PID %s\n",
           title.UTF8String,
           hex4(info.vendor).UTF8String,
           hex4(info.product).UTF8String);
}

#pragma mark - Commands

static NSString *toolsDirectory(const char *argv0)
{
    NSString *exe = [[NSString stringWithUTF8String:argv0] stringByStandardizingPath];
    if (![exe hasPrefix:@"/"]) {
        exe = [[[NSFileManager defaultManager].currentDirectoryPath
                stringByAppendingPathComponent:exe] stringByStandardizingPath];
    }
    NSString *dir = [exe stringByDeletingLastPathComponent];
    NSArray *candidates = @[
        [dir stringByAppendingPathComponent:@"tools"],
        [[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:@"tools"]
    ];
    for (NSString *path in candidates) {
        NSString *script = [path stringByAppendingPathComponent:@"extract_pioneer_profile.py"];
        if ([[NSFileManager defaultManager] isReadableFileAtPath:script]) {
            return path;
        }
    }
    return nil;
}

static id runExtractor(const char *argv0, NSArray<NSString *> *extraArgs, NSError **outError)
{
    NSString *tools = toolsDirectory(argv0);
    if (!tools) {
        if (outError) {
            *outError = errorWithCode(NSPOSIXErrorDomain, ENOENT,
                                      @"tools/extract_pioneer_profile.py not found. Run from the project directory.");
        }
        return nil;
    }
    NSMutableArray *args = [NSMutableArray arrayWithObject:
                            [tools stringByAppendingPathComponent:@"extract_pioneer_profile.py"]];
    [args addObjectsFromArray:extraArgs];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    task.arguments = args;
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    if (![task launchAndReturnError:outError]) {
        return nil;
    }
    [task waitUntilExit];
    NSData *output = [outPipe.fileHandleForReading readDataToEndOfFile];
    NSString *stderrText = [[NSString alloc] initWithData:[errPipe.fileHandleForReading readDataToEndOfFile]
                                                 encoding:NSUTF8StringEncoding];
    if (task.terminationStatus != 0) {
        if (outError) {
            *outError = errorWithCode(NSPOSIXErrorDomain, task.terminationStatus,
                                      stderrText.length ? stderrText : @"extractor failed");
        }
        return nil;
    }
    if (output.length == 0) {
        return @{};
    }
    id json = [NSJSONSerialization JSONObjectWithData:output options:0 error:outError];
    return json;
}

static void printUsage(const char *argv0)
{
    fprintf(stderr,
            "Usage:\n"
            "  %s                 apply DVS routing for the connected profiled device\n"
            "  %s dvs             same as above\n"
            "  %s status          read current USB input routing\n"
            "  %s learn           extract official Pioneer tables and write a profile\n"
            "  %s learn extract   write profiles for every device found in PioneerDDJSetup\n"
            "  %s help            show this help\n",
            argv0, argv0, argv0, argv0, argv0, argv0);
}

static BOOL openPreferred(USBSession *session, USBDeviceInfo *info, NSDictionary **profile, NSError **error)
{
    if (!findPreferredDevice(info, profile)) {
        if (error) {
            *error = errorWithCode(NSPOSIXErrorDomain, ENODEV,
                                   @"No profiled controller found. Connect a DDJ-SZ, or run 'learn' to add a device.");
        }
        return NO;
    }
    if (!usbOpenService(info->service, session, error)) {
        IOObjectRelease(info->service);
        info->service = 0;
        return NO;
    }
    return YES;
}

static int cmdStatus(void)
{
    USBSession session;
    USBDeviceInfo info;
    NSDictionary *profile = nil;
    NSError *error = nil;
    if (!openPreferred(&session, &info, &profile, &error)) {
        fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }

    printDevice(info, profile);

    NSDictionary *firmware = profile[@"firmware"];
    if (firmware) {
        uint8_t raw[2] = { 0, 0 };
        if (usbControl(&session,
                       (uint8_t)parseNumber(firmware[@"bmRequestType"], 0xC0),
                       (uint8_t)parseNumber(firmware[@"bRequest"], 0),
                       (uint16_t)parseNumber(firmware[@"wValue"], 0),
                       (uint16_t)parseNumber(firmware[@"wIndex"], 0x8001),
                       (uint16_t)parseNumber(firmware[@"wLength"], 2),
                       raw,
                       &error)) {
            printf("Firmware: %u.%u\n", raw[0], raw[1]);
        }
    }

    uint8_t buffer[MAX_GET_LEN];
    uint16_t length = 0;
    if (!profileGet(&session, profile, buffer, &length, &error)) {
        fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
        usbClose(&session);
        IOObjectRelease(info.service);
        return 1;
    }
    printRouting(profile, buffer, length);
    usbClose(&session);
    IOObjectRelease(info.service);
    return 0;
}

static int cmdDVS(void)
{
    USBSession session;
    USBDeviceInfo info;
    NSDictionary *profile = nil;
    NSError *error = nil;
    if (!openPreferred(&session, &info, &profile, &error)) {
        fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }

    NSArray *writes = dvsWrites(profile);
    if (writes.count == 0) {
        fprintf(stderr, "error: profile '%s' has no DVS write values.\n", [profile[@"name"] UTF8String]);
        fprintf(stderr, "Run 'learn' and enter confirmed wValues from official software or a capture.\n");
        fprintf(stderr, "This tool will not invent USB writes.\n");
        usbClose(&session);
        IOObjectRelease(info.service);
        return 1;
    }

    printDevice(info, profile);
    printf("Setting DVS routing:\n");
    for (NSDictionary *entry in writes) {
        printf("  %s %s  wValue %s\n",
               [entry[@"slot"] UTF8String],
               [entry[@"label"] UTF8String],
               hex4((uint16_t)parseNumber(entry[@"wValue"], 0)).UTF8String);
        if (!profileSet(&session, profile, (uint16_t)parseNumber(entry[@"wValue"], 0), &error)) {
            fprintf(stderr, "error writing %s: %s\n", [entry[@"slot"] UTF8String], error.localizedDescription.UTF8String);
            usbClose(&session);
            IOObjectRelease(info.service);
            return 1;
        }
    }

    uint8_t buffer[MAX_GET_LEN];
    uint16_t length = 0;
    if (!profileGet(&session, profile, buffer, &length, &error)) {
        fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
        usbClose(&session);
        IOObjectRelease(info.service);
        return 1;
    }
    printRouting(profile, buffer, length);
    usbClose(&session);
    IOObjectRelease(info.service);

    BOOL confirmed = YES;
    NSInteger offset = (NSInteger)parseNumber(profile[@"get"][@"channel_byte_offset"], 1);
    for (NSDictionary *entry in writes) {
        NSInteger slot = slotIndexNamed(profile, entry[@"slot"]);
        if (slot == NSNotFound) {
            continue;
        }
        NSInteger byteIndex = offset + slot;
        if (byteIndex < 0 || byteIndex >= length) {
            continue;
        }
        if (buffer[byteIndex] != parseNumber(entry[@"expect_index"], 0)) {
            confirmed = NO;
        }
    }

    if (confirmed) {
        printf("DVS routing applied. Open Serato → Setup → CD/Vinyl and calibrate the DVS decks.\n");
        return 0;
    }
    fprintf(stderr, "warning: writes were sent but GET did not confirm the expected DVS indexes.\n");
    return 1;
}

static NSDictionary *profileMatchingDevice(NSArray *extracted, uint16_t vendor, uint16_t product)
{
    for (NSDictionary *profile in extracted) {
        if ((uint16_t)parseNumber(profile[@"vendor_id"], 0) == vendor &&
            (uint16_t)parseNumber(profile[@"product_id"], 0) == product) {
            return profile;
        }
    }
    return nil;
}

static int saveExtractedProfiles(NSArray *extracted)
{
    NSError *error = nil;
    int saved = 0;
    for (NSDictionary *profile in extracted) {
        if (saveProfile(profile, &error)) {
            saved++;
            NSArray *dvs = dvsWrites(profile);
            printf("  %s  DVS writes: %lu\n",
                   [profile[@"name"] UTF8String],
                   (unsigned long)dvs.count);
        } else {
            fprintf(stderr, "error saving %s: %s\n",
                    [profile[@"name"] UTF8String],
                    error.localizedDescription.UTF8String);
        }
    }
    return saved > 0 ? 0 : 1;
}

static int cmdLearn(const char *argv0, const char *subcommand)
{
    printf("Learn mode\n");
    printf("Reads official Pioneer tables from PioneerDDJSetup.framework.\n");
    printf("This is a Mach-O parse of the same data otool would dump. No USB writes.\n\n");

    NSError *error = nil;
    printf("Step 1/4  Extract tables from PioneerDDJSetup\n");
    id extracted = runExtractor(argv0, @[], &error);
    if (![extracted isKindOfClass:[NSArray class]] || [extracted count] == 0) {
        fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String ?: "no devices recovered");
        fprintf(stderr, "Install PioneerDDJSetup.framework, or pass a binary with the extractor.\n");
        return 1;
    }

    printf("Recovered official devices:\n");
    for (NSDictionary *profile in extracted) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSDictionary *entry in profile[@"dvs"]) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", entry[@"slot"], entry[@"wValue"]]];
        }
        printf("  %s  %s:%s  DVS[%s]\n",
               [profile[@"name"] UTF8String],
               [profile[@"vendor_id"] UTF8String],
               [profile[@"product_id"] UTF8String],
               [parts componentsJoinedByString:@", "].UTF8String);
    }

    if (subcommand && strcmp(subcommand, "extract") == 0) {
        printf("\nStep 2/4  Writing every recovered profile\n");
        return saveExtractedProfiles(extracted);
    }

    printf("\nStep 2/4  Match a connected USB controller\n");
    NSArray *devices = listUSBDevices();
    NSDictionary *chosen = nil;
    NSDictionary *usbMatch = nil;
    for (NSDictionary *device in devices) {
        uint16_t vendor = (uint16_t)[device[@"vendor"] unsignedIntValue];
        uint16_t product = (uint16_t)[device[@"product"] unsignedIntValue];
        NSDictionary *hit = profileMatchingDevice(extracted, vendor, product);
        printf("  %-24s  VID %s  PID %s%s\n",
               [device[@"name"] UTF8String],
               hex4(vendor).UTF8String,
               hex4(product).UTF8String,
               hit ? "  ← official tables found" : "");
        if (hit && !usbMatch) {
            usbMatch = hit;
            chosen = device;
        }
    }

    if (usbMatch) {
        printf("Matched %s.\n", [usbMatch[@"name"] UTF8String]);
    } else {
        printf("No connected device is in PioneerDDJSetup.framework.\n");
        printf("That framework only knows VID 0x08e4 PIDs 0x0158 / 0x015e / 0x0188 / 0x0191.\n");
        printf("A DDJ-SZ2 (VID 0x2b73 PID 0x0016) needs its own setup binary; this file cannot invent it.\n");
        printf("Select a recovered device to export anyway, or q to quit.\n");
        for (NSUInteger i = 0; i < [extracted count]; i++) {
            printf("  [%lu] %s\n", (unsigned long)(i + 1), [extracted[i][@"name"] UTF8String]);
        }
        printf("Choice: ");
        fflush(stdout);
        NSString *line = readLine();
        if ([line isEqualToString:@"q"] || line.length == 0) {
            releaseDeviceList(devices);
            return 0;
        }
        NSInteger index = [line integerValue];
        if (index < 1 || index > (NSInteger)[extracted count]) {
            fprintf(stderr, "error: invalid selection.\n");
            releaseDeviceList(devices);
            return 2;
        }
        usbMatch = extracted[index - 1];
    }

    printf("\nStep 3/4  Write profile\n");
    if (!saveProfile(usbMatch, &error)) {
        fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
        releaseDeviceList(devices);
        return 1;
    }

    printf("\nStep 4/4  Optional live GET (read-only)\n");
    if (chosen && askYes(@"Probe the connected device with the extracted GET?", YES)) {
        USBSession session;
        io_service_t service = serviceFromDevice(chosen);
        if (usbOpenService(service, &session, &error)) {
            uint8_t buffer[MAX_GET_LEN];
            uint16_t length = 0;
            if (profileGet(&session, usbMatch, buffer, &length, &error)) {
                printRouting(usbMatch, buffer, length);
            } else {
                printf("GET failed: %s\n", error.localizedDescription.UTF8String);
            }
            usbClose(&session);
        } else {
            printf("Open failed: %s\n", error.localizedDescription.UTF8String);
        }
    } else {
        printf("Skipped.\n");
    }

    releaseDeviceList(devices);
    printf("\nUse 'dvs' only if the profile lists confirmed DVS wValues from the official tables.\n");
    return 0;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        const char *command = argc >= 2 ? argv[1] : "dvs";
        const char *subcommand = argc >= 3 ? argv[2] : NULL;

        if (strcmp(command, "help") == 0 || strcmp(command, "-h") == 0 || strcmp(command, "--help") == 0) {
            printUsage(argv[0]);
            return 0;
        }
        if (strcmp(command, "status") == 0) {
            return cmdStatus();
        }
        if (strcmp(command, "dvs") == 0) {
            return cmdDVS();
        }
        if (strcmp(command, "learn") == 0) {
            return cmdLearn(argv[0], subcommand);
        }

        fprintf(stderr, "unknown command: %s\n", command);
        printUsage(argv[0]);
        return 2;
    }
}
