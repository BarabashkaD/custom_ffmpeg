/* Shim: forward to the real mixed-case Windows.h from the MSVC SDK.
   Needed because Linux fs is case-sensitive and code includes <windows.h>
   while the SDK ships Windows.h. */
#include_next <Windows.h>
