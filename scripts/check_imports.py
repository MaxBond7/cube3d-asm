"""Проверка таблицы импорта: для каждой пары DLL/функция вызываем GetProcAddress.
Если чего-то нет — сразу видно, кто виноват в 'Entry Point Not Found'.
Запуск:  python check_imports.py cube3d.exe
"""
import ctypes, struct, sys
from ctypes import wintypes

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.LoadLibraryExW.restype = wintypes.HMODULE
k32.GetProcAddress.restype = ctypes.c_void_p
k32.GetProcAddress.argtypes = [wintypes.HMODULE, ctypes.c_char_p]

LOAD_LIBRARY_AS_DATAFILE = 0x2


def check(path):
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    nsec = struct.unpack_from('<H', d, pe + 6)[0]
    optsize = struct.unpack_from('<H', d, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from('<H', d, opt)[0]
    ddoff = opt + (112 if magic == 0x20b else 96)
    imp_rva, imp_size = struct.unpack_from('<II', d, ddoff + 8)   # data dir 1

    sections = []
    sh = opt + optsize
    for i in range(nsec):
        name, vsize, vaddr, rsize, rptr = struct.unpack_from('<8sIIII', d, sh + 40 * i)
        sections.append((vaddr, vsize, rptr, rsize))

    def rva2off(rva):
        for vaddr, vsize, rptr, rsize in sections:
            if vaddr <= rva < vaddr + max(vsize, rsize):
                return rptr + (rva - vaddr)
        raise ValueError(hex(rva))

    def cstr(off):
        end = d.index(b'\0', off)
        return d[off:end].decode('latin1')

    desc = rva2off(imp_rva)
    dlls = []
    while True:
        oft, ts, fwd, name_rva, ft = struct.unpack_from('<IIIII', d, desc)
        if name_rva == 0:
            break
        dll = cstr(rva2off(name_rva))
        thunk = rva2off(oft or ft)
        funcs = []
        while True:
            v = struct.unpack_from('<Q', d, thunk)[0]
            if v == 0:
                break
            if v & 0x8000000000000000:
                funcs.append(('ordinal', v & 0xffff))
            else:
                funcs.append(('name', cstr(rva2off(v & 0x7fffffff) + 2)))
            thunk += 8
        dlls.append((dll, funcs))
        desc += 20

    print(f'=== {path} ===')
    bad = 0
    for dll, funcs in dlls:
        h = k32.LoadLibraryExW(dll, None, LOAD_LIBRARY_AS_DATAFILE)
        print(f'{dll}: {"OK" if h else "LOAD FAILED"}  ({len(funcs)} imports)')
        for kind, nm in funcs:
            if kind == 'ordinal':
                ok = bool(k32.GetProcAddress(h, ctypes.c_char_p(str(nm).encode())) ) if h else False
                label = f'#{nm}'
            else:
                ok = bool(k32.GetProcAddress(h, nm.encode())) if h else False
                label = nm
            if not ok:
                print(f'   MISSING: {label}')
                bad += 1
    print('all imports resolved' if bad == 0 else f'MISSING: {bad}')
    print()


for p in sys.argv[1:]:
    check(p)
