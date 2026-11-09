//
//  KBColor.cpp  (universal)
//  Bridges user space to the methods of \_SB.KBCD (KBCD0001). The device and
//  its methods come from SSDT-KBLT / SSDT-FANM, which the KBColor setup
//  assistant generates for each laptop (ASUS TUF, Acer Predator, ...). The
//  kext itself knows nothing about the vendor.
//
//  KBCD.GCAP returns what the SSDTs implement (see "Capabilities" below);
//  methods a laptop does not have are simply missing and never called.
//
//  Exactly one property is accepted per call:
//    "Color"       0x000000-0xFFFFFF, whole keyboard          -> SCLR
//    "ZoneColor"   (zone 1-4 << 24) | 0xRRGGBB, one zone      -> SZCL
//    "Effect"      mode | speed << 8 | direction << 16        -> SEFF
//    "Brightness"  0-100                                      -> SBRT
//    "FanMode"     0 = Normal, 1 = Turbo, 2 = Silent / Custom -> SFAN
//    "FanSpeed"    0-100 %, switches to Custom                -> SPCT
//    "Refresh"     any value; publishes the current state
//    "ECSnapshot"  any value; publishes "ECSnapshot", an array with the
//                  bytes of every probed EC region (KBCD.ECRN / ECRD)
//    "ECWrite"     (region << 24) | (offset << 8) | value     -> ECWR
//  ECRD / ECWR exist only in SSDT-KBCP, the temporary probe table the setup
//  assistant installs while it finds EC offsets with the user's help. The
//  final SSDTs have no raw EC access.
//  The ACPI methods range check again and return non-zero for a bad value.
//
//  Diagnostics: at start the kext logs its version, GCAP and which KBCD
//  methods exist ("KBColor: ..." in the kernel log) and publishes them as
//  "Version" and "Methods"; failed calls are logged too. The setup
//  assistant's diagnostic report reads all of this.
//
//  Published: Capabilities, FanMode, FanSpeed, CPUFanRPM, GPUFanRPM, Effect,
//  Brightness, Color. When the fan key is pressed the SSDT sends
//  Notify (KBCD, 0x80); the new state is published and user space is told
//  with kIOMessageServicePropertyChange.
//

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>

#ifndef KBCOLOR_VERSION
#define KBCOLOR_VERSION "dev"
#endif

// Every method an SSDT may provide; used for the "Methods" diagnostic.
static const char *const knownMethods[] = {
    "GCAP", "SCLR", "SZCL", "SEFF", "SBRT", "GLGT", "GCLR",
    "SFAN", "GFAN", "SPCT", "GPCT", "GRPM", "ECRN", "ECRD", "ECWR",
};

class KBColor : public IOService {
    OSDeclareDefaultStructors(KBColor)
    IOACPIPlatformDevice *dev = nullptr;
    IOLock *lock = nullptr;
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn setProperties(OSObject *properties) override;
    IOReturn message(UInt32 type, IOService *provider, void *argument) override;
private:
    IOReturn call(const char *method, UInt32 value);
    IOReturn refresh();
    IOReturn snapshot();
};

OSDefineMetaClassAndStructors(KBColor, IOService)

static const struct { const char *key; const char *method; UInt32 max; } setters[] = {
    { "Color",      "SCLR", 0xFFFFFF },
    { "ZoneColor",  "SZCL", 0x04FFFFFF },
    { "Effect",     "SEFF", 0x020905 },
    { "Brightness", "SBRT", 100 },
    { "FanMode",    "SFAN", 2 },
    { "FanSpeed",   "SPCT", 100 },
    { "ECWrite",    "ECWR", 0x03FFFFFF },
};

bool KBColor::start(IOService *provider)
{
    if (!IOService::start(provider))
        return false;

    dev = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (dev == nullptr)
        return false;
    lock = IOLockAlloc();
    if (lock == nullptr)
        return false;

    setProperty("Version", KBCOLOR_VERSION);
    UInt32 caps = 0;
    bool hasCaps = dev->evaluateInteger("GCAP", &caps) == kIOReturnSuccess;
    if (hasCaps)
        setProperty("Capabilities", caps, 32);

    OSArray *found = OSArray::withCapacity(16);
    char present[96] = "", missing[96] = "";
    for (const char *m : knownMethods) {
        bool ok = dev->validateObject(m) == kIOReturnSuccess;
        if (ok && found != nullptr) {
            const OSSymbol *sym = OSSymbol::withCString(m);
            if (sym != nullptr) { found->setObject(sym); sym->release(); }
        }
        char *dst = ok ? present : missing;
        if (strlen(dst) + 6 < sizeof(present)) { strlcat(dst, m, sizeof(present)); strlcat(dst, " ", sizeof(present)); }
    }
    if (found != nullptr) { setProperty("Methods", found); found->release(); }
    IOLog("KBColor: %s on %s, GCAP %s0x%x\n", KBCOLOR_VERSION, provider->getName(), hasCaps ? "" : "missing ", caps);
    IOLog("KBColor: methods present: %s\n", present);
    IOLog("KBColor: methods missing: %s\n", missing);
    refresh();
    registerService();
    return true;
}

void KBColor::stop(IOService *provider)
{
    if (lock != nullptr) {
        IOLockFree(lock);
        lock = nullptr;
    }
    dev = nullptr;
    IOService::stop(provider);
}

IOReturn KBColor::setProperties(OSObject *properties)
{
    OSDictionary *dict = OSDynamicCast(OSDictionary, properties);
    if (dict == nullptr || dict->getCount() != 1)
        return kIOReturnBadArgument;

    if (dict->getObject("Refresh") != nullptr)
        return refresh();
    if (dict->getObject("ECSnapshot") != nullptr)
        return snapshot();

    for (auto &s : setters) {
        OSObject *obj = dict->getObject(s.key);
        if (obj == nullptr)
            continue;
        OSNumber *num = OSDynamicCast(OSNumber, obj);
        if (num == nullptr || num->unsigned64BitValue() > s.max)
            return kIOReturnBadArgument;
        IOReturn ret = call(s.method, num->unsigned32BitValue());
        if (ret == kIOReturnSuccess)
            refresh();
        return ret;
    }
    return kIOReturnBadArgument;
}

IOReturn KBColor::call(const char *method, UInt32 value)
{
    OSNumber *arg = OSNumber::withNumber(value, 32);
    if (arg == nullptr)
        return kIOReturnNoMemory;

    OSObject *params[1] = { arg };
    UInt32 result = 1;
    IOLockLock(lock);
    IOReturn ret = dev->evaluateInteger(method, &result, params, 1);
    IOLockUnlock(lock);
    arg->release();

    if (ret != kIOReturnSuccess) {
        IOLog("KBColor: %s(0x%x) failed: 0x%x\n", method, (unsigned)value, ret);
        return ret;
    }
    if (result != 0)
        IOLog("KBColor: %s(0x%x) returned %u\n", method, (unsigned)value, (unsigned)result);
    return result == 0 ? kIOReturnSuccess : kIOReturnBadArgument;
}

IOReturn KBColor::message(UInt32 type, IOService *provider, void *argument)
{
    if (type == kIOACPIMessageDeviceNotification && provider == dev && argument != nullptr &&
        *static_cast<UInt32 *>(argument) == 0x80) {
        refresh();
        messageClients(kIOMessageServicePropertyChange);
        return kIOReturnSuccess;
    }
    return IOService::message(type, provider, argument);
}

// Reads whatever the SSDTs implement; missing methods are skipped.
IOReturn KBColor::refresh()
{
    UInt32 mode = 0xFF, pct = 0, cpu = 0, gpu = 0, light = 0, color = 0;
    OSNumber *fan0 = OSNumber::withNumber(0ULL, 32);
    OSNumber *fan1 = OSNumber::withNumber(1ULL, 32);
    if (fan0 == nullptr || fan1 == nullptr) {
        OSSafeReleaseNULL(fan0);
        OSSafeReleaseNULL(fan1);
        return kIOReturnNoMemory;
    }
    OSObject *p0[1] = { fan0 }, *p1[1] = { fan1 };

    IOLockLock(lock);
    IOReturn fret = dev->evaluateInteger("GFAN", &mode);
    if (dev->evaluateInteger("GPCT", &pct) == kIOReturnSuccess)
        setProperty("FanSpeed", pct, 32);
    if (dev->evaluateInteger("GRPM", &cpu, p0, 1) == kIOReturnSuccess &&
        dev->evaluateInteger("GRPM", &gpu, p1, 1) == kIOReturnSuccess) {
        setProperty("CPUFanRPM", cpu, 32);
        setProperty("GPUFanRPM", gpu, 32);
    }
    if (dev->evaluateInteger("GLGT", &light) == kIOReturnSuccess) {
        setProperty("Effect", light & 0xFFFFFF, 32);
        setProperty("Brightness", light >> 24, 32);
    }
    if (dev->evaluateInteger("GCLR", &color) == kIOReturnSuccess)
        setProperty("Color", color, 32);
    IOLockUnlock(lock);
    fan0->release();
    fan1->release();

    if (fret != kIOReturnSuccess)
        return kIOReturnSuccess;  // no fan support on this laptop
    if (mode > 2) {
        removeProperty("FanMode");
        return kIOReturnNotReady;
    }
    setProperty("FanMode", mode, 32);
    return kIOReturnSuccess;
}

// Probe only: reads every region SSDT-KBCP exposes.
IOReturn KBColor::snapshot()
{
    UInt32 count = 0;
    IOLockLock(lock);
    IOReturn ret = dev->evaluateInteger("ECRN", &count);
    OSArray *regions = ret == kIOReturnSuccess ? OSArray::withCapacity(count) : nullptr;
    for (UInt32 i = 0; regions != nullptr && i < count && i < 8; i++) {
        OSNumber *idx = OSNumber::withNumber(i, 32);
        if (idx == nullptr) { ret = kIOReturnNoMemory; break; }
        OSObject *params[1] = { idx };
        OSObject *obj = nullptr;
        ret = dev->evaluateObject("ECRD", &obj, params, 1);
        idx->release();
        OSData *data = OSDynamicCast(OSData, obj);
        if (ret == kIOReturnSuccess && data != nullptr)
            regions->setObject(data);
        else if (ret == kIOReturnSuccess)
            ret = kIOReturnBadArgument;
        OSSafeReleaseNULL(obj);
        if (ret != kIOReturnSuccess) break;
    }
    IOLockUnlock(lock);
    if (ret == kIOReturnSuccess && regions != nullptr)
        setProperty("ECSnapshot", regions);
    OSSafeReleaseNULL(regions);
    return ret;
}
