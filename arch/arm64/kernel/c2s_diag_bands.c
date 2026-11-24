// SPDX-License-Identifier: GPL-2.0-only
/*
 * Issue #5: C-level boot milestone bands for the C2S rescue kernel.
 *
 * arch/arm64/kernel/head.S paints M1/M1b/M2/M3/M4 into rows 0..639 before
 * start_kernel().  Everything painted from C continues the same ladder from
 * row 640 upwards, so a single photo of the panel reads top-down as
 * "asm reached X, then C reached Y".
 *
 * Two entry points, because the mapping they may use has a lifetime:
 *
 *  c2s_band_early()  -  __init.  Covers two phases, both selected at run
 *      time from state that is already published when we get called:
 *
 *      1. "ID map" - memstart_addr still holds its documented -1 sentinel
 *         (arch/arm64/mm/init.c), i.e. arm64_memblock_init() has not run,
 *         so setup_arch() has not finished and TTBR0 still holds the
 *         initial ID map built by create_init_idmap()
 *         (arch/arm64/kernel/pi/map_range.c).  That map identity-maps the
 *         three splash framebuffers as PAGE_KERNEL and DECON0 as device
 *         memory, so the physical addresses are usable directly as virtual
 *         addresses.  The red M2 band painted in __primary_switched()
 *         proves the mapping still works after the kernel image has been
 *         relocated.
 *
 *         Constraint: no call site may sit inside setup_arch() between
 *         cpu_uninstall_idmap() (arch/arm64/kernel/setup.c:320) and
 *         arm64_memblock_init() (setup.c:332) - there the ID map is
 *         already uninstalled while memstart_addr is still -1.  All call
 *         sites live in init/main.c outside setup_arch(), which satisfies
 *         this.
 *
 *      2. "early_*remap" - memstart_addr is valid but the __init memory
 *         has not been released yet (system_state < SYSTEM_FREEING_INITMEM),
 *         so early_ioremap_init() has already run (setup.c:290, which
 *         precedes arm64_memblock_init() at setup.c:332) and the
 *         early_memremap()/early_ioremap() helpers are still callable.
 *         The framebuffer is reached through early_memremap(), which hands
 *         out cacheable normal memory in chunks of at most SZ_256K
 *         (= NR_FIX_BTMAPS pages) per fixmap slot.
 *
 *      Both phases give cacheable memory, so every fill is followed by
 *      dcache_clean_inval_poc() to push the band out to DRAM where DECON
 *      reads it.  Each chunk is unmapped again so no early ioremap slot
 *      leaks (a leak would trigger check_early_ioremap_leak() at
 *      late_initcall).
 *
 *  c2s_late_init()  -  __init, called once from start_kernel() right after
 *      mm_core_init() (init/main.c), where vmap and slab come up.  It takes
 *      the two long-lived mappings the late path needs: an ioremap_wc()
 *      (PROT_NORMAL_NC, write combining) window over each of fb0/fb1, plus
 *      a device ioremap() of DECON0.  ioremap_wc() is the same alias
 *      simplefb takes for fb0 (drivers/video/fbdev/simplefb.c:602), so the
 *      band is written through the same memory type fbcon uses - a
 *      cacheable alias of an NC range would be a mismatched-attribute
 *      alias.
 *
 *  c2s_band()  -  plain .text.  No allocation and no sleeping: a volatile
 *      fill of the pre-taken window, a cache clean (which ends in dsb sy,
 *      so the band is in DRAM before DECON is told to shadow-update), then
 *      the DECON kick.  That is what makes it callable from atomic context
 *      as well as from initcalls, driver probes and run_init_process() -
 *      getgether_connect() runs with interrupts and softirqs disabled
 *      under dwc3's spinlock (u_ether.c), where ioremap()'s GFP_KERNEL
 *      vmalloc would be illegal.  Until c2s_late_init() has run it is a
 *      no-op, so early callers cannot hit vmap before it exists.
 *
 * Where a buffer may be written:
 *
 *  - 0xf1000000 (fb0) and 0xf9800000 (fb1) live inside no-map reserved
 *    regions (reserved-memory/framebuffer@f1000000 and
 *    reserved-memory/audio@f7fb0000), so memblock never hands them out,
 *    they are absent from the linear map (map_mem() skips nomap), and
 *    pfn_is_map_memory() is false for them: safe to write and to ioremap()
 *    at any time.
 *  - 0xfac00000 (fb2) is *unreserved plain RAM* in the 0xe1900000..0x100000000
 *    bank.  It is in the linear map, but memblock may allocate from it as
 *    soon as arm64_memblock_init() has run, so it is painted only while the
 *    ID-map phase is active; both entry points skip it afterwards.
 */

#include <linux/c2s_diag.h>
#include <linux/bitops.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/minmax.h>
#include <linux/sizes.h>
#include <linux/workqueue.h>
#include <asm/cacheflush.h>
#include <asm/memory.h>
#include <asm/page.h>

#define C2S_FB_STRIDE		5760U
#define C2S_BAND_ROWS		128U
#define C2S_BAND_BYTES		(C2S_BAND_ROWS * C2S_FB_STRIDE)	/* 0xb4000 */
#define C2S_FB_SIZE		0x10f6800U

/*
 * One early_memremap()/early_ioremap() call maps at most NR_FIX_BTMAPS
 * pages, which is SZ_256K on every arm64 page size.
 */
#define C2S_MAP_CHUNK		SZ_256K

#define C2S_DECON_PHYS		0x19050000UL
#define C2S_DECON_REG_GLOBAL	0x00
#define C2S_DECON_REG_SHADOW	0x60
#define C2S_DECON_REG_TRIG	0x70
#define C2S_DECON_POLL_MAX	16384

static const unsigned long c2s_fb_phys[] = {
	0xf1000000UL,
	0xf9800000UL,
	0xfac00000UL,
};

/*
 * memstart_addr keeps its -1 sentinel until arm64_memblock_init() runs
 * inside setup_arch(); while it does, TTBR0 still holds the initial ID map,
 * so the physical addresses are usable directly as virtual addresses.
 */
static bool c2s_idmap_alive(void)
{
	return memstart_addr < 0;
}

/*
 * Shared by both entry points, so it must stay in plain .text and must not
 * reference anything __init.  The band is 128 rows of a 5760-byte stride
 * with no padding, hence one contiguous run of u32 pixels.
 */
static void c2s_fill_band(void *addr, unsigned long bytes, u32 colour)
{
	u32 *q = addr;
	unsigned long i;

	for (i = 0; i < bytes / sizeof(u32); i++)
		q[i] = colour;
}

/*
 * Shared DECON0 shadow-update sequence.  Mirrors the c2s_decon_refresh
 * macro in arch/arm64/kernel/head.S; the polls are bounded so a dead DECON
 * cannot hang the boot.
 */
static void c2s_decon_kick(void __iomem *decon)
{
	u32 v;
	int i;

	v = readl(decon + C2S_DECON_REG_SHADOW);
	writel(v | 0x3f, decon + C2S_DECON_REG_SHADOW);

	v = readl(decon + C2S_DECON_REG_GLOBAL);
	writel(v | 0x3, decon + C2S_DECON_REG_GLOBAL);

	v = readl(decon + C2S_DECON_REG_SHADOW);
	writel(v | BIT(31), decon + C2S_DECON_REG_SHADOW);

	for (i = 0; i < C2S_DECON_POLL_MAX; i++)
		if (readl(decon + C2S_DECON_REG_GLOBAL) & BIT(4))
			break;

	v = readl(decon + C2S_DECON_REG_TRIG);
	writel((v & ~BIT(4)) | BIT(0), decon + C2S_DECON_REG_TRIG);

	for (i = 0; i < C2S_DECON_POLL_MAX; i++)
		if (!readl(decon + C2S_DECON_REG_SHADOW))
			break;

	v = readl(decon + C2S_DECON_REG_TRIG);
	writel((v & ~BIT(0)) | BIT(4), decon + C2S_DECON_REG_TRIG);
}

/*
 * Early path - __init only, see the header comment.  Handles the ID-map
 * phase and the early_*remap phase; both give cacheable memory.
 */
void __init c2s_band_early(u32 row, u32 colour)
{
	unsigned long band_off = (unsigned long)row * C2S_FB_STRIDE;
	bool idmap = c2s_idmap_alive();
	void *vaddr;
	unsigned int fb;

	if (band_off + C2S_BAND_BYTES > C2S_FB_SIZE)
		return;

	for (fb = 0; fb < ARRAY_SIZE(c2s_fb_phys); fb++) {
		unsigned long pos = 0;

		/*
		 * 0xfac00000 is unreserved RAM; once arm64_memblock_init()
		 * has run, memblock may hand it out.  Only the ID-map phase,
		 * which is strictly before that, may touch it.
		 */
		if (fb == 2 && !idmap)
			continue;

		while (pos < C2S_BAND_BYTES) {
			unsigned long phys = c2s_fb_phys[fb] + band_off + pos;
			unsigned long align_off = offset_in_page(phys);
			unsigned long paint = min(C2S_BAND_BYTES - pos,
						  C2S_MAP_CHUNK - align_off);
			unsigned long map_len = ALIGN(align_off + paint,
						      PAGE_SIZE);
			void *p;

			if (idmap)
				p = (void *)(phys & PAGE_MASK);
			else
				p = early_memremap(phys & PAGE_MASK, map_len);

			if (!p)
				return;

			c2s_fill_band((u8 *)p + align_off, paint, colour);
			dcache_clean_inval_poc((unsigned long)p + align_off,
					       (unsigned long)p + align_off +
					       paint);

			if (!idmap)
				early_memunmap(p, map_len);

			pos += paint;
		}
	}

	if (idmap)
		vaddr = (void *)C2S_DECON_PHYS;
	else
		vaddr = early_ioremap(C2S_DECON_PHYS, PAGE_SIZE);

	if (vaddr) {
		c2s_decon_kick((void __iomem *)vaddr);
		if (!idmap)
			early_iounmap(vaddr, PAGE_SIZE);
	}
}

/*
 * Long-lived mappings, taken by c2s_late_init() from process context after
 * mm_core_init().  Only fb0 and fb1: 0xfac00000 is unreserved RAM, and
 * ioremap_wc() refuses to map RAM (pfn_is_map_memory() is true there), so
 * that buffer stays ID-map only.
 *
 * ioremap_wc() (PROT_NORMAL_NC) is deliberate: simplefb maps the very same
 * physical range with ioremap_wc() (drivers/video/fbdev/simplefb.c:602), so
 * our alias carries the same memory type as the one fbcon writes through.
 * A cacheable alias of the same range would be a mismatched-attribute
 * alias of an NC region; the plain stores through the NC alias reach
 * memory directly, and mb() orders them against the DECON MMIO.
 */
static void __iomem *c2s_fb_map[2];
static void __iomem *c2s_decon_map;

/*
 * The DECON shadow update is a hardware operation that the vendor code
 * waits for with a timeout of up to 300 ms.  gether_connect() runs with
 * interrupts and softirqs disabled under dwc3's spinlock, so the refresh is
 * deferred to a work item there - stalling the USB control path for
 * hundreds of milliseconds would disturb the very enumeration this
 * diagnostic is meant to observe.  schedule_work() is safe in atomic
 * context, and the workqueues exist by the time any late band is painted
 * (workqueue_init_early() runs before the initcalls that register the UDC).
 */
static void c2s_kick_work_fn(struct work_struct *work)
{
	if (c2s_decon_map)
		c2s_decon_kick(c2s_decon_map);
}

static struct work_struct c2s_kick_work;

void __init c2s_late_init(void)
{
	unsigned int fb;

	if (c2s_fb_map[0] || c2s_fb_map[1])
		return;

	for (fb = 0; fb < ARRAY_SIZE(c2s_fb_map); fb++)
		c2s_fb_map[fb] = ioremap_wc(c2s_fb_phys[fb], C2S_FB_SIZE);

	c2s_decon_map = ioremap(C2S_DECON_PHYS, PAGE_SIZE);
	INIT_WORK(&c2s_kick_work, c2s_kick_work_fn);

	/*
	 * A failed mapping would make every late milestone invisible, which
	 * on the panel is indistinguishable from "the USB path never got
	 * that far".  Say so in the log instead of leaving a silent hole in
	 * the ladder.
	 */
	if (!c2s_fb_map[0] || !c2s_fb_map[1] || !c2s_decon_map)
		pr_err("c2s: milestone mappings incomplete: fb0=%p fb1=%p decon=%p\n",
		       c2s_fb_map[0], c2s_fb_map[1], c2s_decon_map);
}

/*
 * Late path - plain .text, no allocation, no sleeping: legal in atomic
 * context and from any caller once c2s_late_init() has run.
 */
void c2s_band(u32 row, u32 colour)
{
	unsigned long band_off = (unsigned long)row * C2S_FB_STRIDE;
	unsigned int fb;

	if (band_off + C2S_BAND_BYTES > C2S_FB_SIZE)
		return;

	if (!c2s_fb_map[0] && !c2s_fb_map[1])
		return;

	for (fb = 0; fb < ARRAY_SIZE(c2s_fb_map); fb++) {
		void *p;

		if (!c2s_fb_map[fb])
			continue;

		p = (void *)((u8 __force *)c2s_fb_map[fb] + band_off);
		c2s_fill_band(p, C2S_BAND_BYTES, colour);
	}

	/*
	 * The fill went through a non-cacheable alias, so the stores are
	 * already in memory; the barrier only has to order them against the
	 * DECON MMIO that follows.
	 */
	mb();

	if (!c2s_decon_map)
		return;

	if (irqs_disabled())
		schedule_work(&c2s_kick_work);
	else
		c2s_decon_kick(c2s_decon_map);
}
