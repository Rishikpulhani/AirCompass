//
//  MultitouchSupport.h
//  AirCompass
//
//  Reverse-engineered declarations for Apple's private
//  /System/Library/PrivateFrameworks/MultitouchSupport.framework.
//
//  Nothing here is linked directly. Swift resolves each symbol at runtime with
//  dlsym() and casts it to the matching function-pointer typedef below, so a
//  missing or changed framework turns into a recoverable error instead of a
//  launch-time crash.
//

#ifndef AIRCOMPASS_MULTITOUCH_SUPPORT_H
#define AIRCOMPASS_MULTITOUCH_SUPPORT_H

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a multitouch device (built-in trackpad, Magic Trackpad, ...).
typedef void *MTDeviceRef;

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

/// Per-contact path stage reported by the driver.
typedef enum {
    MTTouchStateNotTracking   = 0,
    MTTouchStateStartInRange  = 1,
    MTTouchStateHoverInRange  = 2,
    MTTouchStateMakeTouch     = 3,
    MTTouchStateTouching      = 4,
    MTTouchStateBreakTouch    = 5,
    MTTouchStateLingerInRange = 6,
    MTTouchStateOutOfRange    = 7,
} MTTouchState;

/// One finger contact. Layout must match the framework exactly (96 bytes on
/// arm64 and x86_64); it is verified with a static assertion in shim.c.
typedef struct {
    int32_t  frame;
    double   timestamp;
    int32_t  pathIndex;        // Stable per-finger identifier for the life of a contact.
    int32_t  state;            // MTTouchState
    int32_t  fingerID;
    int32_t  handID;
    MTVector normalized;       // Position in [0,1] x [0,1], origin bottom-left.
    float    zTotal;           // Contact "size" / pressure proxy.
    int32_t  field9;
    float    angle;
    float    majorAxis;
    float    minorAxis;
    MTVector absolute;         // Millimetres.
    int32_t  field14;
    int32_t  field15;
    float    zDensity;
} MTTouch;

/// Contact-frame callback. Invoked on a private high-priority framework thread.
typedef int (*MTContactCallbackFunction)(MTDeviceRef device,
                                         MTTouch *touches,
                                         int32_t numTouches,
                                         double timestamp,
                                         int32_t frame);

// Function-pointer typedefs for dlsym-resolved symbols.
typedef CFMutableArrayRef (*MTDeviceCreateListFn)(void);
typedef void    (*MTRegisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallbackFunction);
typedef void    (*MTUnregisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallbackFunction);
typedef int32_t (*MTDeviceStartFn)(MTDeviceRef, int32_t mode);
typedef int32_t (*MTDeviceStopFn)(MTDeviceRef);
typedef bool    (*MTDeviceIsBuiltInFn)(MTDeviceRef);
typedef int32_t (*MTDeviceGetSensorSurfaceDimensionsFn)(MTDeviceRef, int32_t *width, int32_t *height);

#ifdef __cplusplus
}
#endif

#endif /* AIRCOMPASS_MULTITOUCH_SUPPORT_H */
