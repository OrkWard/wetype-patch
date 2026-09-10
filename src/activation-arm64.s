// WeType 2.2.3 (657), replaces activateServer's mode block at 0x1001187ac.
// Keep the enclosing function's stack frame and all callee-saved registers.
.text
.p2align 2
.globl _WTActivationPatch
_WTActivationPatch:
    mov x20, x22
    mov x0, #-2                 // Darwin RTLD_DEFAULT
    adr x1, Lname
    bl _WTActivationPatch + (0x102a725a8 - 0x1001187ac) // host dlsym stub
    cbz x0, Lsetting            // Missing bridge: zero mode changes, then safe native setup.
    mov x16, x0
    mov x0, x22                 // The activated InputController, borrowed.
    blr x16
Lsetting:
    // Preserve the original G.setting Swift once initialization before the
    // continuation dereferences G.setting at 0x100118880.
    .long 0xf0019168            // adrp x8, 0x103347000
    ldr x8, [x8, #0x5e0]       // G.setting_Wz
    cmn x8, #1
    b.eq Ltime
    .long 0xf0019160            // adrp x0, 0x103347000
    add x0, x0, #0x5e0
    .long 0xf00011a1            // adrp x1, 0x10034f000
    add x1, x1, #0x5e0         // G.setting_WZ
    bl _WTActivationPatch + (0x102a738d4 - 0x1001187ac) // swift_once
Ltime:
    bl _WTActivationPatch + (0x102a70034 - 0x1001187ac) // CACurrentMediaTime
    fmov d8, d0
    .long 0xb00194f3            // adrp x19, 0x1033b5000 at the injection address
    b _WTActivationPatch + (0x100118880 - 0x1001187ac)
Lname:
    .asciz "WTBridgeActivate"
    .space 212 - (. - _WTActivationPatch), 0
