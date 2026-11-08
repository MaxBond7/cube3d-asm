; =====================================================================
;  cube3d.asm  —  программный 3D-рендерер на чистом x64-ассемблере
;                 Win32 + GDI, без CRT и без C-рантайма.
;
;  Что внутри (то, что обычно спрашивают на защите):
;    * окно целиком вручную: WNDCLASSEX, RegisterClassEx, CreateWindowEx,
;      цикл GetMessage/Translate/Dispatch и своя WindowProc;
;    * двойная буферизация: CreateCompatibleDC + BitBlt, поэтому нет мерцания;
;    * вращение куба: x87 (fsin/fcos) для тригонометрии и SSE2 (scalar double)
;      для поворота точек и перспективной проекции;
;    * отсечение невидимых граней по нормали + отсечение граней "в ребро";
;    * направленный свет: яркость = n·L, плюс ambient, через палитру из 32 кистей;
;    * анимация по реальному времени (GetTickCount64), а не по тикам таймера;
;    * свои strcpy и int64->dec (никакой libc), счётчик FPS.
;
;  Сборка:   tools\fasm\FASM.EXE cube3d.asm
;  Клавиши:  Space - пауза,  Left/Right - скорость вращения,
;            Up/Down - наклон,  R - сброс,  Esc - выход.
; =====================================================================
format PE64 GUI 5.0
entry start

include 'INCLUDE\win64a.inc'

; ---------------------------------------------------------------------
;  Поворот точки (без проекции).
;  Вход:  p = указатель на 3 double (x,y,z)
;  Выход: xmm0 = x1, xmm1 = y2, xmm2 = z2
; ---------------------------------------------------------------------
macro rotp p
{
        movsd   xmm0, [p]               ; x
        movsd   xmm1, [p+8]             ; y
        movsd   xmm2, [p+16]            ; z

        movapd  xmm3, xmm0              ; x1 = x*cosB + z*sinB
        mulsd   xmm3, [cosB]
        movapd  xmm4, xmm2
        mulsd   xmm4, [sinB]
        addsd   xmm3, xmm4

        movapd  xmm4, xmm2              ; z1 = z*cosB - x*sinB
        mulsd   xmm4, [cosB]
        movapd  xmm6, xmm0
        mulsd   xmm6, [sinB]
        subsd   xmm4, xmm6

        movapd  xmm5, xmm1              ; y2 = y*cosA - z1*sinA
        mulsd   xmm5, [cosA]
        movapd  xmm6, xmm4
        mulsd   xmm6, [sinA]
        subsd   xmm5, xmm6

        mulsd   xmm4, [cosA]            ; z2 = z1*cosA + y*sinA
        mulsd   xmm1, [sinA]
        addsd   xmm4, xmm1

        movapd  xmm0, xmm3              ; x1
        movapd  xmm1, xmm5              ; y2
        movapd  xmm2, xmm4              ; z2
}

; ---------------------------------------------------------------------
;  Поворот + перспективная проекция.
;  Выход: xmm3 = экранный X, xmm1 = экранный Y, xmm4 = повёрнутый Z
; ---------------------------------------------------------------------
macro xform p
{
        rotp    p                       ; xmm0 = x1, xmm1 = y2, xmm2 = z2

        movapd  xmm6, xmm2              ; scale = focal / (z2 + camDist)
        addsd   xmm6, [camDist]
        movsd   xmm7, [focal]
        divsd   xmm7, xmm6

        mulsd   xmm0, xmm7              ; sx = cenX + x1*scale
        addsd   xmm0, [cenX]
        mulsd   xmm1, xmm7              ; sy = cenY - y2*scale
        movsd   xmm5, [cenY]
        subsd   xmm5, xmm1

        movapd  xmm3, xmm0
        movapd  xmm1, xmm5
        movapd  xmm4, xmm2
}

section '.text' code readable executable

; =====================================================================
;  Точка входа (аналог WinMain, но без CRT)
; =====================================================================
start:
        sub     rsp, 8                  ; выравнивание стека под вызовы API

        invoke  GetModuleHandleA, 0
        mov     [hInst], rax
        mov     [wc.hInstance], rax

        invoke  LoadIconA, 0, IDI_APPLICATION
        mov     [wc.hIcon], rax
        mov     [wc.hIconSm], rax
        invoke  LoadCursorA, 0, IDC_ARROW
        mov     [wc.hCursor], rax

        invoke  RegisterClassExA, wc
        test    eax, eax
        jz      .fail

        ; окно под клиентскую область ровно WND_W x WND_H
        mov     dword [rc.left], 0
        mov     dword [rc.top], 0
        mov     dword [rc.right], WND_W
        mov     dword [rc.bottom], WND_H
        invoke  AdjustWindowRectEx, rc, WS_OVERLAPPEDWINDOW, 0, 0

        invoke  CreateWindowExA, 0, _class, _title, WS_OVERLAPPEDWINDOW, \
                0x100, 0x80, [rc.right], [rc.bottom], 0, 0, [hInst], 0
        test    rax, rax
        jz      .fail
        mov     [hwndMain], rax

        invoke  ShowWindow, rax, SW_SHOW
        invoke  UpdateWindow, rax

; --- цикл сообщений ---------------------------------------------------
.msg_loop:
        invoke  GetMessageA, msg, 0, 0, 0
        cmp     eax, 1
        jb      .end_loop               ; 0 = WM_QUIT, -1 = ошибка
        jne     .msg_loop
        invoke  TranslateMessage, msg
        invoke  DispatchMessageA, msg
        jmp     .msg_loop

.fail:
        invoke  MessageBoxA, 0, _err, _title, MB_ICONERROR

.end_loop:
        invoke  ExitProcess, 0

; =====================================================================
;  WindowProc
; =====================================================================
proc WindowProc uses rbx
        cmp     edx, WM_CREATE
        je      .create
        cmp     edx, WM_SIZE
        je      .size
        cmp     edx, WM_TIMER
        je      .timer
        cmp     edx, WM_PAINT
        je      .paint
        cmp     edx, WM_ERASEBKGND
        je      .erase
        cmp     edx, WM_KEYDOWN
        je      .key
        cmp     edx, WM_DESTROY
        je      .destroy

        invoke  DefWindowProcA, rcx, rdx, r8, r9
        ret

; --- WM_CREATE: ресурсы, палитра, таймер ------------------------------
.create:
        mov     [hwndMain], rcx

        invoke  GetDC, rcx
        mov     [hdcWin], rax
        invoke  CreateCompatibleDC, rax
        mov     [hdcMem], rax

        invoke  CreateSolidBrush, 0x00140C08     ; фон RGB(8,12,20)
        mov     [hbrBack], rax

        invoke  CreateFontA, 16, 0,0,0, 400, 0,0,0, 1, 0,0, 5, 48, _fontName
        mov     [hFont], rax

        ; палитра: 32 кисти и 32 пера (цвет пера = цвет грани, чтобы
        ; заливка не давала швов и не рисовала лишних линий)
        xor     ebx, ebx
.pal:
        mov     eax, ebx
        imul    eax, 45
        xor     edx, edx
        mov     ecx, 31
        div     ecx
        add     eax, 15
        mov     r8d, eax                        ; R

        mov     eax, ebx
        imul    eax, 170
        xor     edx, edx
        div     ecx
        add     eax, 50
        shl     eax, 8
        or      r8d, eax                        ; G

        mov     eax, ebx
        imul    eax, 150
        xor     edx, edx
        div     ecx
        add     eax, 80
        shl     eax, 16
        or      r8d, eax                        ; B

        mov     [tmpColor], r8d
        invoke  CreateSolidBrush, [tmpColor]
        mov     [hbrPalette + rbx*8], rax
        inc     ebx
        cmp     ebx, 32
        jb      .pal

        invoke  SetTimer, [hwndMain], TIMER_ID, TIMER_MS, 0
        invoke  GetTickCount64
        mov     [lastTick], rax
        xor     eax, eax
        ret

; --- WM_SIZE: пересоздать задний буфер --------------------------------
.size:
        movzx   ecx, r9w                        ; width  = LOWORD(lParam)
        shr     r9, 16
        movzx   edx, r9w                        ; height = HIWORD(lParam)
        test    ecx, ecx
        jz      .size_done
        test    edx, edx
        jz      .size_done
        mov     rax, [hdcMem]
        test    rax, rax
        jz      .size_done

        mov     [tmpW], ecx
        mov     [tmpH], edx

        invoke  CreateCompatibleBitmap, [hdcWin], [tmpW], [tmpH]
        mov     rbx, rax
        invoke  SelectObject, [hdcMem], rbx
        mov     [hbmOld], rax

        mov     rax, [hbmBack]
        test    rax, rax
        jz      .size_store
        invoke  DeleteObject, rax
.size_store:
        mov     [hbmBack], rbx

        mov     ecx, [tmpW]
        mov     [clientW], ecx
        mov     [clientRect.right], ecx
        mov     ecx, [tmpH]
        mov     [clientH], ecx
        mov     [clientRect.bottom], ecx
        sub     ecx, 30
        mov     [hintY], ecx
.size_done:
        xor     eax, eax
        ret

; --- WM_TIMER: шаг анимации (по реальному времени, а не по тику) ------
.timer:
        invoke  GetTickCount64
        mov     rcx, rax
        sub     rcx, [lastTick]
        mov     [lastTick], rax
        cmp     rcx, 100                        ; защита от больших пауз
        jbe     .dt_ok
        mov     rcx, 100
.dt_ok:
        cmp     byte [paused], 0
        jne     .timer_done
        cvtsi2sd xmm0, rcx                      ; dt в секундах
        mulsd   xmm0, [msToSec]
        movapd  xmm1, xmm0
        mulsd   xmm0, [tiltSpeed]
        addsd   xmm0, [tiltPhase]
        movsd   [tiltPhase], xmm0
        mulsd   xmm1, [speedB]
        addsd   xmm1, [angleB]
        movsd   [angleB], xmm1
.timer_done:
        invoke  InvalidateRect, [hwndMain], 0, 0
        xor     eax, eax
        ret

; --- WM_PAINT: нарисовать кадр ----------------------------------------
.paint:
        invoke  BeginPaint, [hwndMain], ps
        mov     [hdcPaint], rax
        call    render
        invoke  EndPaint, [hwndMain], ps
        xor     eax, eax
        ret

.erase:
        mov     eax, 1                          ; фон рисуем сами
        ret

; --- WM_KEYDOWN -------------------------------------------------------
.key:
        cmp     r8d, VK_ESCAPE
        je      .key_quit
        cmp     r8d, ' '
        je      .key_pause
        cmp     r8d, VK_LEFT
        je      .key_slower
        cmp     r8d, VK_RIGHT
        je      .key_faster
        cmp     r8d, VK_UP
        je      .key_up
        cmp     r8d, VK_DOWN
        je      .key_down
        cmp     r8d, 'R'
        je      .key_reset
        xor     eax, eax
        ret
.key_pause:
        xor     byte [paused], 1
        xor     eax, eax
        ret
.key_slower:
        movsd   xmm0, [speedB]
        subsd   xmm0, [speedStep]
        movsd   [speedB], xmm0
        xor     eax, eax
        ret
.key_faster:
        movsd   xmm0, [speedB]
        addsd   xmm0, [speedStep]
        movsd   [speedB], xmm0
        xor     eax, eax
        ret
.key_up:
        movsd   xmm0, [tiltAmp]
        addsd   xmm0, [ampStep]
        comisd  xmm0, [ampMax]
        jbe     .up_ok
        movsd   xmm0, [ampMax]
.up_ok:
        movsd   [tiltAmp], xmm0
        xor     eax, eax
        ret
.key_down:
        movsd   xmm0, [tiltAmp]
        subsd   xmm0, [ampStep]
        xorpd   xmm1, xmm1
        comisd  xmm0, xmm1
        jae     .down_ok
        xorpd   xmm0, xmm0
.down_ok:
        movsd   [tiltAmp], xmm0
        xor     eax, eax
        ret
.key_reset:
        movsd   xmm0, [speedB0]
        movsd   [speedB], xmm0
        movsd   xmm0, [tiltAmp0]
        movsd   [tiltAmp], xmm0
        xor     eax, eax
        ret
.key_quit:
        invoke  DestroyWindow, [hwndMain]
        xor     eax, eax
        ret

; --- WM_DESTROY -------------------------------------------------------
.destroy:
        invoke  KillTimer, [hwndMain], TIMER_ID

        invoke  SelectObject, [hdcMem], [hbmOld]
        mov     rax, [hbmBack]
        test    rax, rax
        jz      .no_bmp
        invoke  DeleteObject, rax
.no_bmp:
        invoke  DeleteDC, [hdcMem]
        invoke  ReleaseDC, [hwndMain], [hdcWin]

        invoke  DeleteObject, [hFont]
        invoke  DeleteObject, [hbrBack]
        xor     ebx, ebx
.free_pal:
        invoke  DeleteObject, [hbrPalette + rbx*8]
        inc     ebx
        cmp     ebx, 32
        jb      .free_pal

        invoke  PostQuitMessage, 0
        xor     eax, eax
        ret
endp

; =====================================================================
;  render — рисует кадр в задний буфер и блитит на экран
; =====================================================================
proc render uses rbx rsi rdi
        mov     rax, [hdcMem]
        test    rax, rax
        jz      .out

; --- FPS --------------------------------------------------------------
        invoke  GetTickCount64
        mov     [nowTick], rax
        inc     dword [frames]
        mov     rcx, rax
        sub     rcx, [fpsT0]
        cmp     rcx, 500
        jb      .fps_ok
        mov     eax, [frames]
        imul    rax, 1000
        xor     edx, edx
        div     rcx
        mov     [fps], rax
        mov     rax, [nowTick]
        mov     [fpsT0], rax
        mov     dword [frames], 0
.fps_ok:

; --- фон --------------------------------------------------------------
        invoke  FillRect, [hdcMem], clientRect, [hbrBack]

; --- тригонометрия (x87) ----------------------------------------------
        ; наклон качается: angleA = tiltBase + tiltAmp*sin(tiltPhase),
        ; поэтому куб никогда не встаёт строго "в плоскость"
        fld     qword [tiltPhase]
        fsin
        fmul    qword [tiltAmp]
        fadd    qword [tiltBase]
        fstp    qword [angleA]

        fld     qword [angleA]
        fsin
        fstp    qword [sinA]
        fld     qword [angleA]
        fcos
        fstp    qword [cosA]
        fld     qword [angleB]
        fsin
        fstp    qword [sinB]
        fld     qword [angleB]
        fcos
        fstp    qword [cosB]

        mov     eax, [clientW]
        mov     ecx, [clientH]
        cmp     eax, ecx
        cmovg   eax, ecx                        ; min(w,h)
        cvtsi2sd xmm0, eax
        mulsd   xmm0, [fovScale]
        movsd   [focal], xmm0

        cvtsi2sd xmm0, dword [clientW]
        mulsd   xmm0, [half]
        movsd   [cenX], xmm0
        cvtsi2sd xmm0, dword [clientH]
        mulsd   xmm0, [half]
        movsd   [cenY], xmm0

; --- проекция 8 вершин ------------------------------------------------
        lea     rsi, [pts]
        lea     rdi, [scrX]
        lea     rbx, [scrY]
        mov     r10d, 8
.vloop:
        xform   rsi
        cvtsd2si eax, xmm3
        mov     [rdi], eax
        cvtsd2si eax, xmm1
        mov     [rbx], eax
        add     rsi, 24
        add     rdi, 4
        add     rbx, 4
        dec     r10d
        jnz     .vloop

; --- повёрнутые нормали 6 граней --------------------------------------
        lea     rsi, [pts + 8*24]
        xor     edi, edi
        mov     r10d, 6
.nloop:
        rotp    rsi
        movsd   [normX + rdi], xmm0
        movsd   [normY + rdi], xmm1
        movsd   [normZ + rdi], xmm2
        add     rsi, 24
        add     rdi, 8
        dec     r10d
        jnz     .nloop

; --- грани: алгоритм художника (дальние -> ближние) -------------------
        invoke  GetStockObject, NULL_PEN          ; без обводки - никаких "полосок"
        invoke  SelectObject, [hdcMem], rax

        xor     ebx, ebx                        ; порядок граней 0..5
.fill_order:
        mov     [faceOrder + rbx], bl
        inc     ebx
        cmp     ebx, 6
        jb      .fill_order

        mov     ecx, 1                          ; сортировка вставками по nz
.sort_outer:
        movzx   eax, byte [faceOrder + rcx]
        movsd   xmm0, [normZ + rax*8]
        mov     edx, ecx
.sort_inner:
        test    edx, edx
        jz      .sort_place
        movzx   r8d, byte [faceOrder + rdx - 1]
        movsd   xmm1, [normZ + r8*8]
        comisd  xmm1, xmm0
        jae     .sort_place                     ; по убыванию: дальние первыми
        mov     [faceOrder + rdx], r8b
        dec     edx
        jmp     .sort_inner
.sort_place:
        mov     [faceOrder + rdx], al
        inc     ecx
        cmp     ecx, 6
        jb      .sort_outer

        xor     ebx, ebx
.floop:
        movzx   eax, byte [faceOrder + rbx]
        mov     [curFace], eax

        movsd   xmm2, [normZ + rax*8]
        andpd   xmm2, dqword [absMask]
        comisd  xmm2, [sliverMin]
        jb      .fnext                          ; грань почти в ребро - пропуск

        ; intensity = ambient + gain * max(0, n . L)
        movsd   xmm0, [normX + rax*8]
        mulsd   xmm0, [lightX]
        movsd   xmm1, [normY + rax*8]
        mulsd   xmm1, [lightY]
        addsd   xmm0, xmm1
        movsd   xmm1, [normZ + rax*8]
        mulsd   xmm1, [lightZ]
        addsd   xmm0, xmm1                      ; dot = n . L
        xorpd   xmm3, xmm3
        maxsd   xmm0, xmm3
        mulsd   xmm0, [shadeGain]
        addsd   xmm0, [ambient]
        mulsd   xmm0, [c31]
        cvtsd2si eax, xmm0
        cmp     eax, 31
        jbe     .idx_ok
        mov     eax, 31
.idx_ok:
        mov     rdx, [hbrPalette + rax*8]
        invoke  SelectObject, [hdcMem], rdx

        mov     eax, [curFace]
        lea     rsi, [faces + rax*4]
        movzx   eax, byte [rsi]
        mov     edx, [scrX + rax*4]
        mov     [polyPts + 0], edx
        mov     edx, [scrY + rax*4]
        mov     [polyPts + 4], edx
        movzx   eax, byte [rsi+1]
        mov     edx, [scrX + rax*4]
        mov     [polyPts + 8], edx
        mov     edx, [scrY + rax*4]
        mov     [polyPts + 12], edx
        movzx   eax, byte [rsi+2]
        mov     edx, [scrX + rax*4]
        mov     [polyPts + 16], edx
        mov     edx, [scrY + rax*4]
        mov     [polyPts + 20], edx
        movzx   eax, byte [rsi+3]
        mov     edx, [scrX + rax*4]
        mov     [polyPts + 24], edx
        mov     edx, [scrY + rax*4]
        mov     [polyPts + 28], edx

        invoke  Polygon, [hdcMem], polyPts, 4
.fnext:
        inc     ebx
        cmp     ebx, 6
        jb      .floop

; --- HUD --------------------------------------------------------------
        invoke  SetBkMode, [hdcMem], TRANSPARENT
        invoke  SetTextColor, [hdcMem], 0x00FFD890
        invoke  SelectObject, [hdcMem], [hFont]

        lea     rdi, [hudBuf]
        mov     rcx, _hudFps
        call    str_append
        mov     rdi, rax
        mov     rcx, [fps]
        call    uint_append
        mov     rdi, rax
        mov     rcx, _hudSpin
        call    str_append
        mov     rdi, rax

        movsd   xmm0, [speedB]
        mulsd   xmm0, [rad2deg]
        mulsd   xmm0, [ten]
        cvtsd2si rcx, xmm0
        mov     rax, rcx
        xor     edx, edx
        mov     r9, 10
        div     r9
        mov     [tmpRem], rdx
        mov     rcx, rax
        call    uint_append
        mov     rdi, rax
        mov     byte [rdi], '.'
        inc     rdi
        mov     rcx, [tmpRem]
        call    uint_append
        mov     rdi, rax
        mov     rcx, _hudDeg
        call    str_append
        mov     rdi, rax

        cmp     byte [paused], 0
        je      .no_pause
        mov     rcx, _hudPaused
        call    str_append
        mov     rdi, rax
.no_pause:
        mov     rax, rdi
        lea     rcx, [hudBuf]
        sub     rax, rcx
        mov     [hudLen], eax

        invoke  TextOutA, [hdcMem], 14, 10, hudBuf, [hudLen]
        invoke  TextOutA, [hdcMem], 14, [hintY], _hint, _hintLen

; --- блит на экран ----------------------------------------------------
        invoke  BitBlt, [hdcPaint], 0, 0, [clientW], [clientH], [hdcMem], 0, 0, SRCCOPY
.out:
        ret
endp

; =====================================================================
;  str_append: rcx -> строка, rdi -> куда. Возвращает новый rdi в rax.
; =====================================================================
proc str_append
.copy:
        mov     al, [rcx]
        test    al, al
        jz      .done
        mov     [rdi], al
        inc     rcx
        inc     rdi
        jmp     .copy
.done:
        mov     rax, rdi
        ret
endp

; =====================================================================
;  uint_append: rcx = число, rdi -> куда. Возвращает новый rdi в rax.
; =====================================================================
proc uint_append
        lea     r8, [scratch + 31]
        mov     byte [r8], 0
        mov     rax, rcx
        mov     r9, 10
.dig:
        xor     edx, edx
        div     r9
        add     dl, '0'
        dec     r8
        mov     [r8], dl
        test    rax, rax
        jnz     .dig
.copy:
        mov     al, [r8]
        test    al, al
        jz      .done
        mov     [rdi], al
        inc     r8
        inc     rdi
        jmp     .copy
.done:
        mov     rax, rdi
        ret
endp

; =====================================================================
section '.data' data readable writeable

  WND_W = 880
  WND_H = 620
  TIMER_ID = 1
  TIMER_MS = 10

  _title     db 'Cube3D - pure x64 assembly', 0
  _class     db 'CUBE3D_ASM', 0
  _err       db 'RegisterClassEx / CreateWindowEx failed', 0
  _fontName  db 'Consolas', 0

  _hudFps    db 'FPS: ', 0
  _hudSpin   db '    spin: ', 0
  _hudDeg    db ' deg/s', 0
  _hudPaused db '    [PAUSED]', 0
  _hint      db 'Space - pause   Left/Right - spin   Up/Down - tilt   R - reset   Esc - quit'
  _hintLen = $ - _hint

  align 16

; куб: 8 вершин + 6 нормалей (нормали в том же порядке, что и грани)
  pts:
        dq -1.0, -1.0, -1.0
        dq  1.0, -1.0, -1.0
        dq  1.0,  1.0, -1.0
        dq -1.0,  1.0, -1.0
        dq -1.0, -1.0,  1.0
        dq  1.0, -1.0,  1.0
        dq  1.0,  1.0,  1.0
        dq -1.0,  1.0,  1.0
        dq  0.0,  0.0,  1.0          ; грань 0: +Z, вершины 4,5,6,7
        dq  0.0,  0.0, -1.0          ; грань 1: -Z, вершины 1,0,3,2
        dq  1.0,  0.0,  0.0          ; грань 2: +X, вершины 5,1,2,6
        dq -1.0,  0.0,  0.0          ; грань 3: -X, вершины 0,4,7,3
        dq  0.0,  1.0,  0.0          ; грань 4: +Y, вершины 7,6,2,3
        dq  0.0, -1.0,  0.0          ; грань 5: -Y, вершины 0,1,5,4

  faces: db 4,5,6,7
         db 1,0,3,2
         db 5,1,2,6
         db 0,4,7,3
         db 7,6,2,3
         db 0,1,5,4

; --- математика -------------------------------------------------------
  camDist     dq 4.0
  fovScale    dq 0.72
  half        dq 0.5
  c31         dq 31.0
  ten         dq 10.0
  rad2deg     dq 57.29577951308232
  msToSec     dq 0.001
  ampStep     dq 0.05
  ampMax      dq 1.2

; свет: направление НА источник (верх-лево-спереди), нормализовано
  lightX      dq -0.80
  lightY      dq -0.50
  lightZ      dq -0.33
  ambient     dq 0.15
  shadeGain   dq 0.85
  sliverMin   dq 0.05

  align 16
  absMask     dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF

  faceOrder   db 6 dup(0)
  curFace     dd 0

  speedStep   dq 0.0872664626        ; +/- 5 градусов в секунду (шаг)
  speedB0     dq 1.0471975512        ; 60 град/с - вращение
  tiltAmp0    dq 0.55                ; амплитуда качания ~31 градус

  angleA      dq 0.35
  angleB      dq 0.8
  tiltPhase   dq 0.0
  tiltAmp     dq 0.55
  tiltBase    dq 0.35
  tiltSpeed   dq 0.45
  speedB      dq 1.0471975512
  lastTick    dq 0
  paused      db 0

  sinA        dq 0.0
  cosA        dq 1.0
  sinB        dq 0.0
  cosB        dq 1.0
  focal       dq 500.0
  cenX        dq 440.0
  cenY        dq 310.0

  scrX        dd 8 dup(0)
  scrY        dd 8 dup(0)
  normX       dq 6 dup(0.0)
  normY       dq 6 dup(0.0)
  normZ       dq 6 dup(0.0)
  polyPts     dd 8 dup(0)

; --- состояние --------------------------------------------------------
  hInst       dq 0
  hwndMain    dq 0
  hdcWin      dq 0
  hdcMem      dq 0
  hdcPaint    dq 0
  hbmBack     dq 0
  hbmOld      dq 0
  hFont       dq 0
  hbrBack     dq 0
  hbrPalette  dq 32 dup(0)
  tmpColor    dd 0

  clientW     dd WND_W
  clientH     dd WND_H
  hintY       dd WND_H - 30
  tmpW        dd 0
  tmpH        dd 0
  tmpRem      dq 0
  hudLen      dd 0

  fps         dq 0
  frames      dd 0
  fpsT0       dq 0
  nowTick     dq 0

  hudBuf      rb 160
  scratch     rb 32

  wc          WNDCLASSEX sizeof.WNDCLASSEX, CS_HREDRAW+CS_VREDRAW, WindowProc, 0, 0, 0, 0, 0, 0, 0, _class, 0
  msg         MSG
  ps          PAINTSTRUCT
  rc          RECT
  clientRect  RECT 0, 0, WND_W, WND_H

section '.idata' import data readable writeable

  library kernel32,'KERNEL32.DLL', user32,'USER32.DLL', gdi32,'GDI32.DLL'

  import  kernel32, \
          GetModuleHandleA,'GetModuleHandleA', \
          ExitProcess,'ExitProcess', \
          GetTickCount64,'GetTickCount64'

  import  user32, \
          RegisterClassExA,'RegisterClassExA', \
          CreateWindowExA,'CreateWindowExA', \
          DefWindowProcA,'DefWindowProcA', \
          GetMessageA,'GetMessageA', \
          TranslateMessage,'TranslateMessage', \
          DispatchMessageA,'DispatchMessageA', \
          PostQuitMessage,'PostQuitMessage', \
          MessageBoxA,'MessageBoxA', \
          LoadIconA,'LoadIconA', \
          LoadCursorA,'LoadCursorA', \
          ShowWindow,'ShowWindow', \
          UpdateWindow,'UpdateWindow', \
          DestroyWindow,'DestroyWindow', \
          AdjustWindowRectEx,'AdjustWindowRectEx', \
          FillRect,'FillRect', \
          SetTimer,'SetTimer', \
          KillTimer,'KillTimer', \
          InvalidateRect,'InvalidateRect', \
          BeginPaint,'BeginPaint', \
          EndPaint,'EndPaint', \
          GetDC,'GetDC', \
          ReleaseDC,'ReleaseDC'

  import  gdi32, \
          CreateCompatibleDC,'CreateCompatibleDC', \
          CreateCompatibleBitmap,'CreateCompatibleBitmap', \
          DeleteDC,'DeleteDC', \
          SelectObject,'SelectObject', \
          DeleteObject,'DeleteObject', \
          BitBlt,'BitBlt', \
          CreateSolidBrush,'CreateSolidBrush', \
          CreatePen,'CreatePen', \
          CreateFontA,'CreateFontA', \
          GetStockObject,'GetStockObject', \
          SetBkMode,'SetBkMode', \
          SetTextColor,'SetTextColor', \
          TextOutA,'TextOutA', \
          Polygon,'Polygon'
