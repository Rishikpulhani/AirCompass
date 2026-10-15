#include "MultitouchSupport.h"
#include <stddef.h>

// Guard the reverse-engineered layout: if these drift, every coordinate read
// from the framework would be garbage.
_Static_assert(sizeof(MTTouch) == 96, "MTTouch must be 96 bytes");
_Static_assert(offsetof(MTTouch, normalized) == 32, "MTTouch.normalized offset");
_Static_assert(offsetof(MTTouch, absolute) == 68, "MTTouch.absolute offset");
