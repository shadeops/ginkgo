#include <raygui.h>

// We need to build a standalone raygui.a but 
//  ```
//  const raygui = b.addStaticLibrary(...)
//  raygui.addCSourceFiles(&.{
//     "raygui_wrapper/raygui_wrapper.h",
//  }, raygui_flags);
//  ```
//
// results in a empty library file. (Apparently extensions matter?)
//
// This works around the issue.
