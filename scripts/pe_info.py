"""Minimal PE header dump: what exactly FASM produced.
Usage:  python pe_info.py hello_console.exe [hello_gui.exe ...]
ASCII-only output so it works with any console codepage.
"""
import struct, sys

MACHINE = {0x8664: 'x64', 0x14c: 'x86', 0xaa64: 'ARM64'}
SUBSYS = {2: 'GUI', 3: 'CONSOLE'}


def info(path):
    d = open(path, 'rb').read()
    print(f'=== {path}  ({len(d)} bytes) ===')
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    print(f'DOS stub : {d[:2].decode("latin1")}  e_lfanew = {pe}')
    assert d[pe:pe + 4] == b'PE\0\0', 'no PE signature'

    machine, nsec, _, _, _, optsize, chars = struct.unpack_from('<HHIIIHH', d, pe + 4)
    print(f'COFF     : machine={MACHINE.get(machine, hex(machine))}  sections={nsec}  chars=0x{chars:04x}')

    opt = pe + 24
    magic = struct.unpack_from('<H', d, opt)[0]
    entry = struct.unpack_from('<I', d, opt + 16)[0]
    imagebase = struct.unpack_from('<Q', d, opt + 24)[0]
    salign, falign = struct.unpack_from('<II', d, opt + 32)
    subsys = struct.unpack_from('<H', d, opt + 68)[0]
    print(f'Optional : {"PE32+" if magic == 0x20b else "PE32"}  '
          f'imagebase=0x{imagebase:x}  entry RVA=0x{entry:x} -> VA 0x{imagebase + entry:x}')
    print(f'           subsystem={SUBSYS.get(subsys, subsys)}  '
          f'section align={salign}  file align={falign}')

    sh = opt + optsize
    for i in range(nsec):
        name, vsize, vaddr, rawsize, rawptr, *_ = struct.unpack_from('<8sIIIIIIHHI', d, sh + 40 * i)
        print(f'  section {name.rstrip(bytes(1)).decode("latin1"):8} RVA=0x{vaddr:06x} '
              f'vsize=0x{vsize:06x}  file=0x{rawptr:06x} size=0x{rawsize:06x}')
        if name.startswith(b'.text'):
            body = d[rawptr:rawptr + min(rawsize, 60)]
            print('    code: ' + ' '.join(f'{b:02x}' for b in body) + ' ...')
    print()


for p in sys.argv[1:]:
    info(p)
