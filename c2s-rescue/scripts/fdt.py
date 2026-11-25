"""Minimal FDT (DTB) reader: structure, properties, phandles."""
import struct

FDT_BEGIN_NODE=1; FDT_END_NODE=2; FDT_PROP=3; FDT_NOP=4; FDT_END=9

class Node:
    __slots__=('name','props','kids','parent','phandle','path')
    def __init__(s,name,parent=None):
        s.name=name; s.props=[]; s.kids=[]; s.parent=parent; s.phandle=None; s.path=None
    def prop(s,n):
        for k,v in s.props:
            if k==n: return v
        return None
    def kid(s,n):
        for k in s.kids:
            if k.name==n: return k
        return None
    def walk(s):
        yield s
        for k in s.kids: yield from k.walk()

def parse(buf):
    magic,tot,off_s,off_str,off_rsv,ver,lcv,cpu,size_str,size_struct=struct.unpack('>10I',buf[:40])
    assert magic==0xd00dfeed, hex(magic)
    strings=buf[off_str:off_str+size_str]
    p=off_s; end=off_s+size_struct
    root=None; stack=[]
    while p<end:
        tok,=struct.unpack('>I',buf[p:p+4]); p+=4
        if tok==FDT_BEGIN_NODE:
            nul=buf.index(b'\x00',p)
            name=buf[p:nul].decode()
            p=(nul+4)&~3
            n=Node(name, stack[-1] if stack else None)
            if stack: stack[-1].kids.append(n)
            stack.append(n)
            if root is None: root=n
        elif tok==FDT_END_NODE:
            stack.pop()
        elif tok==FDT_PROP:
            ln,noff=struct.unpack('>II',buf[p:p+8]); p+=8
            val=buf[p:p+ln]; p=(p+ln+3)&~3
            name=strings[noff:strings.index(b'\x00',noff)].decode()
            stack[-1].props.append((name,val))
            if name=='phandle' or name=='linux,phandle':
                stack[-1].phandle=struct.unpack('>I',val)[0]
        elif tok==FDT_NOP:
            pass
        elif tok==FDT_END:
            break
        else:
            raise ValueError('bad token %d at %d'%(tok,p))
    # assign paths
    def assign(n, prefix):
        if n.name in ('', '/'):
            n.path=prefix
        else:
            n.path=(prefix if prefix!='/' else '')+'/'+n.name
        for k in n.kids: assign(k,n.path)
    assign(root,'')
    return root

def props_of(node):
    return {k:v for k,v in node.props}

def s(v):
    if v and v[-1]==0 and b'\x00' not in v[:-1]:
        return v[:-1].decode('utf-8','replace')
    return v.decode('utf-8','replace')

def cells(v):
    return list(struct.unpack('>%dI'%(len(v)//4),v[:len(v)//4*4]))
