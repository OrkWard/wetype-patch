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
    cbz x0, Ltime               // Missing bridge: zero changes, no retry.
    mov x16, x0
    mov x0, x22                 // The activated InputController, borrowed.
    blr x16
Ltime:
    bl _WTActivationPatch + (0x102a70034 - 0x1001187ac) // CACurrentMediaTime
    fmov d8, d0
    .long 0xb00194f3            // adrp x19, 0x1033b5000 at the injection address
    b _WTActivationPatch + (0x100118880 - 0x1001187ac)
Lname:
    .asciz "WTBridgeActivate"
    .space 212 - (. - _WTActivationPatch), 0
