#!/usr/bin/env python3
"""Generate c2s overlay anchor nodes (DTS include) for the c2s rescue base DTB.

sboot (Samsung SF_BOOTLOADER for exynos9830) applies the boot-image DTBO
entries (libufdt) onto the FDT found in the boot image "dt" slot before every
boot.  Each stock overlay's /__fixups__ resolves phandles through labels in
the base /__symbols__; an unresolvable path aborts the boot
("failed to perform fixups in overlay" -> "[UFDT] DT Overlay FAIL.").

This generator emits, for every fixup target that the base does not provide,
a shell node at the stock path carrying the stock label, so that
DTC_FLAGS -@ generates a /__symbols__ entry that resolves the fixup.

Inputs (host-side fixtures, never committed):
  <fixtures>/stock-base.dtb          stock mb008 boot-image dt-slot FDT
  <fixtures>/overlay0..8.dtbo        stock dtbo.img entries
  <fixtures>/prev-base-without-anchors.dtb   our base before anchors
"""
import argparse, json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fdt

# properties that carry phandle references (single or list)
REF_PROPS = {
    'clocks', 'clock-names', 'resets', 'reset-names', 'gpios', 'gpio',
    'iommus', 'dmas', 'power-domains', 'phys', 'pwms', 'mboxes',
    'interconnects', 'interrupts-extended', 'memory-region', 'usb-role-switch',
    'sound-dai', 'dai', 'codec', 'remote-endpoint', 'link',
}
# properties that are plain data (never phandle references)
RAW_PROPS = {
    'reg', 'reg-names', 'ranges', 'interrupts', 'interrupt-parent',
    'interrupt-map', 'status', 'compatible', 'clock-ranges', 'phandle',
    'linux,phandle', 'name', 'pinctrl-0', 'pinctrl-1', 'pinctrl-2',
    'pinctrl-names', 'samsung,pins', 'samsung,pin-function', 'samsung,pin-pud',
    'samsung,pin-drv', 'samsung,pin-con-pdn', 'samsung,pin-pud-pdn',
    'samsung,pin-con', 'samsung,pin-pud-pdn', 'sound-name-prefix',
}


def is_string(v):
    """True for FDT string / string-list values."""
    if not v or v[-1] != 0:
        return False
    for seg in v.split(b'\x00')[:-1]:
        if not seg:
            return False
        if not all(32 <= b < 127 or b in (9, 10, 13) for b in seg):
            return False
    return True


def fmt_cells(cs):
    return '<' + ' '.join('0x%02x' % c for c in cs) + '>'


class AnchorGen:
    def __init__(self, fixtures, base_dtb):
        self.stock = fdt.parse(open(os.path.join(fixtures, 'stock-base.dtb'), 'rb').read())
        self.ours = fdt.parse(open(base_dtb, 'rb').read())
        self.ssym = self._syms(self.stock)
        self.osym = self._syms(self.ours)
        self.stock_phandles = {n.phandle for n in self.stock.walk() if n.phandle}

    @staticmethod
    def _syms(root):
        n = root.kid('__symbols__')
        return {k: fdt.s(v) for k, v in n.props} if n else {}

    def fixup_union(self, overlays):
        union = set()
        for p in overlays:
            r = fdt.parse(open(p, 'rb').read())
            fx = r.kid('__fixups__')
            if fx:
                union |= {k for k, _ in fx.props}
        return union

    def node_at(self, root, path):
        n = root
        for part in [p for p in path.split('/') if p]:
            n = n.kid(part)
            if n is None:
                return None
        return n

    def build(self, overlays):
        union = self.fixup_union(overlays)
        missing = sorted(union - set(self.osym))
        labels_by_path = {}
        for l in missing:
            p = self.ssym.get(l)
            if p is None:
                continue
            labels_by_path.setdefault('/' + p.lstrip('/'), []).append(l)
        # a stock label may map to a path that is an overlay fragment node
        # (/fragment@lcd/__overlay__/s6e3hab_ddi); such paths are not part of the
        # base tree - the fixup target then is a *path* fixup, handled by the
        # __local_fixups__/path mechanism; we only provide labels for real nodes.
        for path in list(labels_by_path):
            if self.node_at(self.stock, path) is None:
                continue
        # keep top-most paths only (parent subtree contains children)
        paths = sorted(labels_by_path)
        top = [p for p in paths
               if not any(q != p and q.rstrip('/') + '/' in p.rstrip('/') + '/'
                          for q in paths)]
        sub = []
        for p in top:
            n = self.node_at(self.stock, p)
            if n is None:
                continue
            sub.append((p, n))
        # label -> node mapping (labels may sit on nested nodes inside an
        # emitted subtree - e.g. the abox child labels)
        label_of_node = {}
        for p in paths:
            n = self.node_at(self.stock, p)
            if n is None:
                continue
            for l in labels_by_path.get(p, []):
                label_of_node.setdefault(id(n), []).append(l)
        # nodes of the emitted subtrees get fresh phandles
        sub_nodes = []
        for _, n in sub:
            sub_nodes.extend(n.walk())
        node_ph = {}
        for i, n in enumerate(sub_nodes):
            if n.phandle:
                node_ph[id(n)] = 0x10001 + i
        ph2node = {n.phandle: n for n in sub_nodes if n.phandle}
        ctx = dict(missing=missing, labels_by_path=labels_by_path, sub=sub,
                   label_of_node=label_of_node, sub_nodes=sub_nodes,
                   node_ph=node_ph, ph2node=ph2node)
        ctx['stock_phandles'] = self.stock_phandles
        return ctx

    def prop_lines(self, n, ctx):
        out = []
        for k, v in n.props:
            if k in ('phandle', 'linux,phandle'):
                continue
            if k in RAW_PROPS or is_string(v):
                if is_string(v):
                    segs = [x.decode() for x in v.split(b'\x00')[:-1]]
                    out.append((k, ', '.join('"%s"' % x for x in segs)))
                else:
                    out.append((k, fmt_cells(fdt.cells(v))))
                continue
            if len(v) % 4 == 0 and len(v) > 0:
                cells = fdt.cells(v)
                ok = True
                new = []
                for c in cells:
                    if c in ctx['stock_phandles']:
                        tgt = ctx['ph2node'].get(c)
                        if tgt is not None and id(tgt) in ctx['node_ph']:
                            new.append(ctx['node_ph'][id(tgt)])
                        else:
                            ok = False
                            break
                    else:
                        new.append(c)
                if ok:
                    out.append((k, fmt_cells(new)))
                continue
            # unknown blob -> drop
        return out

    def emit_node(self, n, depth, out, ctx, force_disabled=True):
        labs = ctx['label_of_node'].get(id(n), [])
        pad = '\t' * depth
        lbl = ' '.join(l + ':' for l in labs)
        out.append(f'{pad}{lbl}{n.name} {{')
        props = self.prop_lines(n, ctx)
        for k, val in props:
            out.append(f'{pad}\t{k} = {val};')
        if force_disabled and not any(k == 'status' for k, _ in props):
            out.append(f'{pad}\tstatus = "disabled";')
        for kid in n.kids:
            self.emit_node(kid, depth + 1, out, ctx)
        out.append(f'{pad}}};')

    def render(self, ctx):
        hdr = '''/*
 * c2s rescue: stock DTBO overlay anchor nodes - GENERATED, do not edit.
 *
 * Regenerate with c2s-rescue/scripts/gen-overlay-anchors.py; it needs the
 * stock mb008 boot-image dt-slot FDT and the 9 stock dtbo.img entries as
 * host-side fixtures (they stay out of git).
 *
 * sboot (exynos9830) applies the boot-image DTBO onto the FDT in the boot
 * image dt slot before every boot.  Every /__fixups__ label of the stock dtbo
 * entries has to resolve through the base /__symbols__, otherwise sboot
 * aborts the boot:
 *   "failed to perform fixups in overlay" -> "[UFDT] DT Overlay FAIL."
 * Measured on the mb008 stock set: base 864 labels, dtbo union 225 labels.
 *
 * The nodes below are shells at the stock paths (from the stock boot-image
 * dt-slot FDT) with the stock labels.  Phandle reference properties are kept
 * only when every referenced node is part of these shells (renumbered
 * 0x10001+); otherwise they are dropped, because a raw stock phandle number
 * would alias an unrelated node of this base.  status = "disabled" keeps the
 * rescue kernel from probing shells that this mainline tree does not drive;
 * an overlay may still re-enable a node explicitly.
 */'''
        out = [hdr, '/ {']
        for p, n in ctx['sub']:
            parts = [x for x in p.split('/') if x]
            for i, part in enumerate(parts):
                if i == len(parts) - 1:
                    self.emit_node(n, i, out, ctx)
                    for j in range(len(parts) - 2, -1, -1):
                        out.append('\t' * j + '};')
                else:
                    out.append('\t' * i + f'{part} {{')
        out.append('};')
        return '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--fixtures', required=True)
    ap.add_argument('--base-dtb', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--report')
    a = ap.parse_args()

    overlays = sorted(
        os.path.join(a.fixtures, f) for f in os.listdir(a.fixtures)
        if f.startswith('overlay') and f.endswith('.dtbo'))
    g = AnchorGen(a.fixtures, a.base_dtb)
    ctx = g.build(overlays)
    text = g.render(ctx)
    with open(a.out, 'w') as fh:
        fh.write(text)
    if a.report:
        with open(a.report, 'w') as fh:
            json.dump({'missing_labels': ctx['missing'],
                       'paths': sorted(ctx['labels_by_path']),
                       'subtree_nodes': len(ctx['sub_nodes'])}, fh, indent=1)
    print('anchor labels: %d, shells: %d, subtree nodes: %d'
          % (len(ctx['missing']), len(ctx['sub']), len(ctx['sub_nodes'])))


if __name__ == '__main__':
    main()
