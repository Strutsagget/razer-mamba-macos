// razerctl – styr belysningen på Razer Mamba (2015 Chroma) native på macOS (arm64/x86_64).
// Bygger på Razer-protokollet som dokumenterats av OpenRazer.
//
// Bygg:  clang -O2 -o razerctl razerctl.c -framework IOKit -framework CoreFoundation
// Kör:   ./razerctl off | on | static R G B | brightness 0-255 | spectrum

#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RAZER_VID 0x1532
#define REPORT_LEN 90

// Mamba-varianter som använder samma kommandon (transaction id 0x3F)
static const int MAMBA_PIDS[] = {
    0x0044, // Mamba 2015 trådbunden
    0x0045, // Mamba 2015 trådlös
};

#define VARSTORE      0x01
#define BACKLIGHT_LED 0x05

typedef struct {
    uint8_t data[REPORT_LEN];
} razer_report;

// Layout: [0]status [1]transaction_id [2-3]remaining [4]protocol [5]data_size
//         [6]command_class [7]command_id [8-87]args [88]crc [89]reserved
static razer_report make_report(uint8_t cls, uint8_t id, uint8_t size, const uint8_t *args) {
    razer_report r;
    memset(&r, 0, sizeof r);
    r.data[1] = 0x3F;
    r.data[5] = size;
    r.data[6] = cls;
    r.data[7] = id;
    if (args) memcpy(&r.data[8], args, size);
    uint8_t crc = 0;
    for (int i = 2; i < 88; i++) crc ^= r.data[i];
    r.data[88] = crc;
    return r;
}

static int is_mamba(int pid) {
    for (size_t k = 0; k < sizeof MAMBA_PIDS / sizeof *MAMBA_PIDS; k++)
        if (pid == MAMBA_PIDS[k]) return 1;
    return 0;
}

// Skickar rapporten som USB SET_REPORT direkt till enheten (kontrollkanal 0).
// Går förbi HID-lagret och kräver därför ingen Input Monitoring-behörighet.
static int send_report_usb(const razer_report *r) {
    // Ett idVendor-filter i matchningen ger inga träffar på IOUSBHostDevice,
    // så vi hämtar alla USB-enheter och filtrerar i loopen.
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");

    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return -1;

    int ok = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        int vid = 0, pid = 0;
        CFNumberRef v = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBVendorID),
                                                        kCFAllocatorDefault, 0);
        if (v) { CFNumberGetValue(v, kCFNumberIntType, &vid); CFRelease(v); }
        CFNumberRef p = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBProductID),
                                                        kCFAllocatorDefault, 0);
        if (p) { CFNumberGetValue(p, kCFNumberIntType, &pid); CFRelease(p); }
        if (vid != RAZER_VID || !is_mamba(pid)) { IOObjectRelease(service); continue; }

        IOCFPlugInInterface **plugin = NULL;
        IOUSBDeviceInterface **dev = NULL;
        SInt32 score;
        kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                             kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);
        if (kr != KERN_SUCCESS || !plugin) {
            if (getenv("RAZER_DEBUG")) fprintf(stderr, "usb pid=0x%04x plugin=0x%x\n", pid, kr);
            continue;
        }
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                  (LPVOID *)&dev);
        IODestroyPlugInInterface(plugin);
        if (!dev) { if (getenv("RAZER_DEBUG")) fprintf(stderr, "usb pid=0x%04x inget device-interface\n", pid); continue; }

        IOUSBDevRequest req = {
            .bmRequestType = USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface), // 0x21
            .bRequest = 0x09,      // HID SET_REPORT
            .wValue = 0x0300,      // feature report, id 0
            .wIndex = 0x00,        // gränssnitt 0
            .wLength = REPORT_LEN,
            .pData = (void *)r->data,
        };
        IOReturn res = (*dev)->DeviceRequest(dev, &req);
        if (getenv("RAZER_DEBUG")) fprintf(stderr, "usb pid=0x%04x request=0x%x\n", pid, res);
        if (res == kIOReturnSuccess) ok++;
        (*dev)->Release(dev);
    }
    IOObjectRelease(iter);
    return ok ? 0 : -1;
}

// Provar USB-vägen först och faller tillbaka på HID.
static int send_report_hid(const razer_report *r);
static int send_report(const razer_report *r) {
    if (send_report_usb(r) == 0) return 0;
    return send_report_hid(r);
}

static int send_report_hid(const razer_report *r) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int vid = RAZER_VID;
    CFNumberRef vidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), vidNum);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);

    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    int ok = 0, found = 0;
    if (set) {
        CFIndex n = CFSetGetCount(set);
        IOHIDDeviceRef *devs = calloc(n, sizeof *devs);
        CFSetGetValues(set, (const void **)devs);
        for (CFIndex i = 0; i < n; i++) {
            int pid = 0;
            CFNumberRef p = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDProductIDKey));
            if (p) CFNumberGetValue(p, kCFNumberIntType, &pid);
            int supported = 0;
            for (size_t k = 0; k < sizeof MAMBA_PIDS / sizeof *MAMBA_PIDS; k++)
                if (pid == MAMBA_PIDS[k]) supported = 1;
            if (!supported) continue;
            found = 1;
            // Musen exponerar flera HID-gränssnitt; bara ett tar emot feature reports.
            // Vi provar alla och räknar lyckade. Open kan nekas (kIOReturnNotPermitted)
            // utan Input Monitoring-behörighet, men SetReport fungerar ofta ändå.
            IOReturn oe = IOHIDDeviceOpen(devs[i], kIOHIDOptionsTypeNone);
            IOReturn res = IOHIDDeviceSetReport(devs[i], kIOHIDReportTypeFeature, 0,
                                                r->data, REPORT_LEN);
            if (getenv("RAZER_DEBUG"))
                fprintf(stderr, "pid=0x%04x open=0x%x setreport=0x%x\n", pid, oe, res);
            if (res == kIOReturnSuccess) ok++;
            if (oe == kIOReturnSuccess) IOHIDDeviceClose(devs[i], kIOHIDOptionsTypeNone);
        }
        free(devs);
        CFRelease(set);
    }
    CFRelease(vidNum);
    CFRelease(match);
    IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
    CFRelease(mgr);

    if (!found) { fprintf(stderr, "Ingen Razer Mamba hittades.\n"); return 1; }
    if (!ok)    { fprintf(stderr, "Kunde inte skicka kommandot till musen.\n"); return 1; }
    return 0;
}

static int clamp255(const char *s) {
    int v = atoi(s);
    return v < 0 ? 0 : v > 255 ? 255 : v;
}

static void usage(void) {
    fprintf(stderr,
        "Användning:\n"
        "  razerctl off                 Släck all belysning\n"
        "  razerctl on                  Tänd (regnbåge/spectrum)\n"
        "  razerctl spectrum            Regnbågscykel\n"
        "  razerctl static R G B        Fast färg, t.ex. static 0 255 0\n"
        "  razerctl wave [left|right]   Färgvåg\n"
        "  razerctl breathing [R G B]   Andning i en färg (utan färg: slumpade)\n"
        "  razerctl reactive R G B      Lyser upp när du klickar\n"
        "  razerctl brightness 0-255    Ljusstyrka\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 1; }
    const char *cmd = argv[1];
    uint8_t a[8] = {0};

    // Klass 0x03 / id 0x0A = "standard matrix effect"
    if (!strcmp(cmd, "off")) {
        a[0] = 0x00;
        razer_report r = make_report(0x03, 0x0A, 1, a);
        return send_report(&r);
    }
    if (!strcmp(cmd, "on") || !strcmp(cmd, "spectrum")) {
        // Se till att ljusstyrkan inte är 0, annars syns ingenting
        if (!strcmp(cmd, "on")) {
            uint8_t b[3] = {VARSTORE, BACKLIGHT_LED, 255};
            razer_report br = make_report(0x03, 0x03, 3, b);
            send_report(&br);
        }
        a[0] = 0x04;
        razer_report r = make_report(0x03, 0x0A, 1, a);
        return send_report(&r);
    }
    if (!strcmp(cmd, "static") && argc == 5) {
        a[0] = 0x06;
        a[1] = clamp255(argv[2]);
        a[2] = clamp255(argv[3]);
        a[3] = clamp255(argv[4]);
        razer_report r = make_report(0x03, 0x0A, 4, a);
        return send_report(&r);
    }
    if (!strcmp(cmd, "wave")) {
        a[0] = 0x01;
        a[1] = (argc == 3 && !strcmp(argv[2], "left")) ? 0x02 : 0x01;
        razer_report r = make_report(0x03, 0x0A, 2, a);
        return send_report(&r);
    }
    if (!strcmp(cmd, "breathing")) {
        a[0] = 0x03;
        if (argc == 5) {            // en färg
            a[1] = 0x01;
            a[2] = clamp255(argv[2]);
            a[3] = clamp255(argv[3]);
            a[4] = clamp255(argv[4]);
        } else {                    // slumpade färger
            a[1] = 0x03;
        }
        razer_report r = make_report(0x03, 0x0A, 8, a);
        return send_report(&r);
    }
    if (!strcmp(cmd, "reactive") && argc == 5) {
        a[0] = 0x02;
        a[1] = 0x02;                // hur länge den lyser efter klick (1 kort – 4 lång)
        a[2] = clamp255(argv[2]);
        a[3] = clamp255(argv[3]);
        a[4] = clamp255(argv[4]);
        razer_report r = make_report(0x03, 0x0A, 5, a);
        return send_report(&r);
    }
    if (!strcmp(cmd, "brightness") && argc == 3) {
        uint8_t b[3] = {VARSTORE, BACKLIGHT_LED, (uint8_t)clamp255(argv[2])};
        razer_report r = make_report(0x03, 0x03, 3, b);
        return send_report(&r);
    }
    usage();
    return 1;
}
