/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Low-level CPU initialisation
 * Based on arch/arm/kernel/head.S
 *
 * Copyright (C) 1994-2002 Russell King
 * Copyright (C) 2003-2012 ARM Ltd.
 * Authors:	Catalin Marinas <catalin.marinas@arm.com>
 *		Will Deacon <will.deacon@arm.com>
 */

#include <linux/linkage.h>
#include <linux/init.h>
#include <linux/pgtable.h>

#include <asm/asm_pointer_auth.h>
#include <asm/assembler.h>
#include <asm/boot.h>
#include <asm/bug.h>
#include <asm/ptrace.h>
#include <asm/asm-offsets.h>
#include <asm/cache.h>
#include <asm/cputype.h>
#include <asm/el2_setup.h>
#include <asm/elf.h>
#include <asm/image.h>
#include <asm/kernel-pgtable.h>
#include <asm/kvm_arm.h>
#include <asm/memory.h>
#include <asm/pgtable-hwdef.h>
#include <asm/page.h>
#include <asm/scs.h>
#include <asm/smp.h>
#include <asm/sysreg.h>
#include <asm/stacktrace/frame.h>
#include <asm/thread_info.h>
#include <asm/virt.h>

#include "efi-header.S"

#if (PAGE_OFFSET & 0x1fffff) != 0
#error PAGE_OFFSET must be at least 2MB aligned
#endif

/*
 * Kernel startup entry point.
 * ---------------------------
 *
 * The requirements are:
 *   MMU = off, D-cache = off, I-cache = on or off,
 *   x0 = physical address to the FDT blob.
 *
 * Note that the callee-saved registers are used for storing variables
 * that are useful before the MMU is enabled. The allocations are described
 * in the entry routines.
 */
	__HEAD
	/*
	 * DO NOT MODIFY. Image header expected by Linux boot-loaders.
	 */
	efi_signature_nop			// special NOP to identity as PE/COFF executable
	b	primary_entry			// branch to kernel start, magic
	.quad	0				// Image load offset from start of RAM, little-endian
	le64sym	_kernel_size_le			// Effective size of kernel image, little-endian
	le64sym	_kernel_flags_le		// Informative flags, little-endian
	.quad	0				// reserved
	.quad	0				// reserved
	.quad	0				// reserved
	.ascii	ARM64_IMAGE_MAGIC		// Magic number
	.long	.Lpe_header_offset		// Offset to the PE header.

	__EFI_PE_HEADER

	.section ".idmap.text","a"

	/*
	 * The following callee saved general purpose registers are used on the
	 * primary lowlevel boot path:
	 *
	 *  Register   Scope                      Purpose
	 *  x19        primary_entry() .. start_kernel()        whether we entered with the MMU on
	 *  x20        primary_entry() .. __primary_switch()    CPU boot mode
	 *  x21        primary_entry() .. start_kernel()        FDT pointer passed at boot in x0
	 */

/*
 * Issue #4 diagnostic trigger (guarded by CONFIG_C2S_DIAG).
 *
 * Mirrors lk3rd's decon_show_buffer_update() (platform/exynos9830/dpu/
 * decon_core.c:114-134) so a freshly painted framebuffer is actually
 * pushed to the panel.  Register offsets/bits are from
 * platform/exynos9830/include/dpu/cal/regs-decon.h:
 *
 *   GLOBAL_CONTROL         0x0000   DECON_EN 1<<1  DECON_EN_F 1<<0  SRESET 1<<28
 *   SHADOW_REG_UPDATE_REQ  0x0060   GLOBAL 1<<31   FOR_DECON 0x3f
 *   HW_SW_TRIG_CONTROL     0x0070   HW_TRIG_EN 1<<0  HW_TRIG_MASK_DECON 1<<4
 *
 * Every access is a read-modify-write (decon_write_mask,
 * include/dpu/decon.h:476-482): val = (val & mask) | (old & ~mask).  The
 * masks used here are the same ones the vendor's refresh uses, so:
 *   - GLOBAL_CONTROL is written with mask 0x3 (DECON_EN|DECON_EN_F), so
 *     the written bit 28 (SRESET) is whatever the read returned for it,
 *     not an unconditional 0.  Vendor evidence: decon_reg_reset() writes
 *     bit 28 as 1 *on purpose* (cal/decon_reg.c:33, write_mask with
 *     mask=SRESET) and then polls for it to self-clear (cal/decon_reg.c:34-38),
 *     i.e. bit 28 is a self-clearing write-1-to-reset bit.  decon_reg_
 *     direct_on_off() uses exactly the mask 0x3 shown above
 *     (cal/decon_reg.c:66-67) and therefore has the same property: it
 *     preserves whatever the hardware reported for bit 28.  We match the
 *     vendor behaviour but we do not prove the value read for bit 28 is
 *     0 at this point in the boot, so this is a known limitation, not a
 *     safety guarantee.
 *   - HW_SW_TRIG_CONTROL is touched with mask 0x11 = HW_TRIG_EN|
 *     HW_TRIG_MASK_DECON only; sboot's handoff value 0x3070 (bits 4,5,6,
 *     12,13 set: the DECON/slave masks plus edge polarity/active value,
 *     cmd_boot.c:730-731) is preserved and restored by the RMW, and the
 *     bits 5,6,12,13 are not written.  0x11 is not an encodable ARM64
 *     logical immediate, so it is applied as two single-bit ops.
 *
 * The two polls are iteration-bounded (16384 iterations each).  That
 * bounds the *loop*: with the arch timer disabled before kernel_entry
 * (cmd_boot.c:732-734) no real timeout can be built here, so a DECON
 * that never sets RUN_STATUS or never clears SHADOW_REG_UPDATE_REQ only
 * costs iterations and the sequence then falls through.  It does NOT
 * protect against a read from 0x19050000 that hangs the bus or raises
 * an external abort - that would stop the CPU regardless of the counter,
 * and nothing in this file can prevent it.
 *
 * Uses only x4 (base), x5 (data) and x6 (poll counter) — all
 * caller-saved scratch.  x0..x3 hold the bootloader arguments that
 * preserve_boot_args() records and x19..x21 carry boot state across M2,
 * so neither group is clobbered at either call site.  That is a
 * register-usage claim only, not a statement that the MMIO accesses
 * themselves cannot fault.
 *
 * id is a unique label suffix (GNU as \@ is avoided for portability).
 */
	.macro	c2s_decon_refresh, id
	movz	x4, #0x1905, lsl #16		// DECON0_BASE_ADDR (display_sfr.h:40)

	// 1) all-win shadow update request: SHADOW_REG_UPDATE_REQ |= 0x3f
	ldr	w5, [x4, #0x60]
	orr	w5, w5, #0x3f
	str	w5, [x4, #0x60]

	// 2) decon_reg_direct_on_off(1): GLOBAL_CONTROL |= DECON_EN|DECON_EN_F
	//    mask 0x3 -> bit 28 (SRESET) is written back as read (see note above)
	ldr	w5, [x4, #0x00]
	orr	w5, w5, #0x3
	str	w5, [x4, #0x00]

	// 3) decon_reg_update_req_global: SHADOW_REG_UPDATE_REQ |= 1<<31
	ldr	w5, [x4, #0x60]
	orr	w5, w5, #0x80000000
	str	w5, [x4, #0x60]

	// 4) wait for RUN_STATUS (GLOBAL_CONTROL bit 4), bounded
	mov	x6, #0x4000
.Lc2s_run_wait_\id:
	ldr	w5, [x4, #0x00]
	tbnz	w5, #4, .Lc2s_run_ok_\id
	subs	x6, x6, #1
	b.ne	.Lc2s_run_wait_\id
.Lc2s_run_ok_\id:

	// 5) set_trigger(ENABLE): HW_SW_TRIG_CONTROL = (old & ~0x11) | 0x1
	//    clears HW_TRIG_MASK_DECON, sets HW_TRIG_EN -> unmask + arm trigger
	ldr	w5, [x4, #0x70]
	bic	w5, w5, #0x10			// HW_TRIG_MASK_DECON (1<<4)
	orr	w5, w5, #0x1			// HW_TRIG_EN (1<<0)
	str	w5, [x4, #0x70]

	// 6) wait for SHADOW_REG_UPDATE_REQ to clear, bounded
	mov	x6, #0x4000
.Lc2s_upd_wait_\id:
	ldr	w5, [x4, #0x60]
	cbz	w5, .Lc2s_upd_ok_\id
	subs	x6, x6, #1
	b.ne	.Lc2s_upd_wait_\id
.Lc2s_upd_ok_\id:

	// 7) set_trigger(DISABLE): HW_SW_TRIG_CONTROL = (old & ~0x11) | 0x10
	//    restores the masked state (matches sboot's 0x3070 handoff)
	ldr	w5, [x4, #0x70]
	bic	w5, w5, #0x1			// HW_TRIG_EN
	orr	w5, w5, #0x10			// HW_TRIG_MASK_DECON
	str	w5, [x4, #0x70]
	dsb	sy
	.endm

SYM_CODE_START(primary_entry)
#ifdef CONFIG_C2S_DIAG
	/*
	 * M1 (issue #4 diagnostic candidate): first instructions executed by
	 * the kernel. The entry contract holds: MMU = off, D-cache = off,
	 * so a plain store reaches DRAM directly. Everything below uses
	 * registers only (no data references, no calls, no stack) and never
	 * touches the bootloader arguments x0..x3, which preserve_boot_args()
	 * records right afterwards.
	 *
	 * Paint a white band into the framebuffers at 0xf1000000 (visible
	 * splash buffer), 0xf9800000 and 0xfac00000 (the two buffers the DECON
	 * windows are configured on by lk3rd): 1440 px wide, rows 0..127,
	 * stride 5760 bytes (1440 * 4, a8r8g8b8). White 0xffffffff is the
	 * only colour that is unambiguous under any channel order.
	 *
	 * Assumption (documented in c2s-rescue/docs/diag-milestones.md): the
	 * bootloader really entered with the MMU and D-cache off, and at
	 * least one of the three buffers is scanned out by DECON.
	 */
	movz	x4, #0xffff
	movk	x4, #0xffff, lsl #16
	movk	x4, #0xffff, lsl #32
	movk	x4, #0xffff, lsl #48
	movz	x9, #5760			// stride in bytes
	mov	x10, #128			// band height in rows

	movz	x5, #0xf100, lsl #16		// framebuffer 0: 0xf1000000
	mov	x8, x5
	mov	x11, x10
.Lc2s_m1_fb0_row:
	mov	x6, x8
	mov	x7, #360			// 5760 / 16
.Lc2s_m1_fb0_col:
	stp	x4, x4, [x6], #16
	subs	x7, x7, #1
	b.ne	.Lc2s_m1_fb0_col
	add	x8, x8, x9
	subs	x11, x11, #1
	b.ne	.Lc2s_m1_fb0_row

	movz	x5, #0xf980, lsl #16		// framebuffer 1: 0xf9800000
	mov	x8, x5
	mov	x11, x10
.Lc2s_m1_fb1_row:
	mov	x6, x8
	mov	x7, #360
.Lc2s_m1_fb1_col:
	stp	x4, x4, [x6], #16
	subs	x7, x7, #1
	b.ne	.Lc2s_m1_fb1_col
	add	x8, x8, x9
	subs	x11, x11, #1
	b.ne	.Lc2s_m1_fb1_row

	movz	x5, #0xfac0, lsl #16		// framebuffer 2: 0xfac00000
	mov	x8, x5
	mov	x11, x10
.Lc2s_m1_fb2_row:
	mov	x6, x8
	mov	x7, #360
.Lc2s_m1_fb2_col:
	stp	x4, x4, [x6], #16
	subs	x7, x7, #1
	b.ne	.Lc2s_m1_fb2_col
	add	x8, x8, x9
	subs	x11, x11, #1
	b.ne	.Lc2s_m1_fb2_row

	dsb	sy

	// Push the freshly painted band to the panel.  The MMU is still off
	// here, so 0x19050000 is reached as a plain physical device access
	// (exactly like sboot/lk3rd do it), with no mapping required.
	c2s_decon_refresh m1
#endif
	bl	record_mmu_state
	bl	preserve_boot_args

	adrp	x1, early_init_stack
	mov	sp, x1
	mov	x29, xzr
	adrp	x0, __pi_init_idmap_pg_dir
	mov	x1, xzr
	bl	__pi_create_init_idmap

	/*
	 * If the page tables have been populated with non-cacheable
	 * accesses (MMU disabled), invalidate those tables again to
	 * remove any speculatively loaded cache lines.
	 */
	cbnz	x19, 0f
	dmb     sy
	mov	x1, x0				// end of used region
	adrp    x0, __pi_init_idmap_pg_dir
	adr_l	x2, dcache_inval_poc
	blr	x2
	b	1f

	/*
	 * If we entered with the MMU and caches on, clean the ID mapped part
	 * of the primary boot code to the PoC so we can safely execute it with
	 * the MMU off.
	 */
0:	adrp	x0, __idmap_text_start
	adr_l	x1, __idmap_text_end
	adr_l	x2, dcache_clean_poc
	blr	x2

1:	mov	x0, x19
	bl	init_kernel_el			// w0=cpu_boot_mode
	mov	x20, x0

	/*
	 * The following calls CPU setup code, see arch/arm64/mm/proc.S for
	 * details.
	 * On return, the CPU will be ready for the MMU to be turned on and
	 * the TCR will have been set.
	 */
	bl	__cpu_setup			// initialise processor
	b	__primary_switch
SYM_CODE_END(primary_entry)

	__INIT
SYM_CODE_START_LOCAL(record_mmu_state)
	mrs	x19, CurrentEL
	cmp	x19, #CurrentEL_EL2
	mrs	x19, sctlr_el1
	b.ne	0f
	mrs	x19, sctlr_el2
0:
CPU_LE( tbnz	x19, #SCTLR_ELx_EE_SHIFT, 1f	)
CPU_BE( tbz	x19, #SCTLR_ELx_EE_SHIFT, 1f	)
	tst	x19, #SCTLR_ELx_C		// Z := (C == 0)
	and	x19, x19, #SCTLR_ELx_M		// isolate M bit
	csel	x19, xzr, x19, eq		// clear x19 if Z
	ret

	/*
	 * Set the correct endianness early so all memory accesses issued
	 * before init_kernel_el() occur in the correct byte order. Note that
	 * this means the MMU must be disabled, or the active ID map will end
	 * up getting interpreted with the wrong byte order.
	 */
1:	eor	x19, x19, #SCTLR_ELx_EE
	bic	x19, x19, #SCTLR_ELx_M
	b.ne	2f
	pre_disable_mmu_workaround
	msr	sctlr_el2, x19
	b	3f
2:	pre_disable_mmu_workaround
	msr	sctlr_el1, x19
3:	isb
	mov	x19, xzr
	ret
SYM_CODE_END(record_mmu_state)

/*
 * Preserve the arguments passed by the bootloader in x0 .. x3
 */
SYM_CODE_START_LOCAL(preserve_boot_args)
	mov	x21, x0				// x21=FDT

	adr_l	x0, boot_args			// record the contents of
	stp	x21, x1, [x0]			// x0 .. x3 at kernel entry
	stp	x2, x3, [x0, #16]

	cbnz	x19, 0f				// skip cache invalidation if MMU is on
	dmb	sy				// needed before dc ivac with
						// MMU off

	add	x1, x0, #0x20			// 4 x 8 bytes
	b	dcache_inval_poc		// tail call
0:	str_l   x19, mmu_enabled_at_boot, x0
	ret
SYM_CODE_END(preserve_boot_args)

	/*
	 * Initialize CPU registers with task-specific and cpu-specific context.
	 *
	 * Create a final frame record at task_pt_regs(current)->stackframe, so
	 * that the unwinder can identify the final frame record of any task by
	 * its location in the task stack. We reserve the entire pt_regs space
	 * for consistency with user tasks and kthreads.
	 */
	.macro	init_cpu_task tsk, tmp1, tmp2
	msr	sp_el0, \tsk

	ldr	\tmp1, [\tsk, #TSK_STACK]
	add	sp, \tmp1, #THREAD_SIZE
	sub	sp, sp, #PT_REGS_SIZE

	stp	xzr, xzr, [sp, #S_STACKFRAME]
	mov	\tmp1, #FRAME_META_TYPE_FINAL
	str	\tmp1, [sp, #S_STACKFRAME_TYPE]
	add	x29, sp, #S_STACKFRAME

	scs_load_current

	adr_l	\tmp1, __per_cpu_offset
	ldr	w\tmp2, [\tsk, #TSK_TI_CPU]
	ldr	\tmp1, [\tmp1, \tmp2, lsl #3]
	set_this_cpu_offset \tmp1
	.endm

/*
 * The following fragment of code is executed with the MMU enabled.
 *
 *   x0 = __pa(KERNEL_START)
 */
SYM_FUNC_START_LOCAL(__primary_switched)
#ifdef CONFIG_C2S_DIAG
	/*
	 * M2 (issue #4): first code running with the MMU and D-cache on,
	 * still before start_kernel(). TTBR0 still holds the initial ID
	 * map, which now identity-maps the three splash framebuffers
	 * (see create_init_idmap() in pi/map_range.c), so the stores below
	 * hit DRAM at the same VAs as M1 used with the MMU off.
	 *
	 * Colour: red 0xffff0000 in a8r8g8b8 (M1 = white rows 0..127),
	 * band rows 128..255 = offset 128*5760 = 0xb4000, 128 rows =
	 * 0xb4000 bytes per buffer. Because the D-cache is on now, the
	 * painted range is cleaned to the point of coherency with
	 * dc civac so the DECON scanout (and a later ramdump) sees it.
	 */
	movz	x4, #0x0000
	movk	x4, #0xffff, lsl #16		// red 0xffff0000 (AARRGGBB)
	movz	x9, #5760			// stride in bytes
	mov	x10, #128			// band height in rows
	movz	x11, #0xb, lsl #16		// band row offset 0xb4000
	movk	x11, #0x4000			// 128 rows * 5760 bytes

	movz	x5, #0xf100, lsl #16		// framebuffer 0: 0xf1000000
	add	x5, x5, x11			// band start
	mov	x8, x5
	mov	x12, x10
.Lc2s_m2_fb0_row:
	mov	x6, x8
	mov	x7, #360			// 5760 / 16
.Lc2s_m2_fb0_col:
	stp	x4, x4, [x6], #16
	subs	x7, x7, #1
	b.ne	.Lc2s_m2_fb0_col
	add	x8, x8, x9
	subs	x12, x12, #1
	b.ne	.Lc2s_m2_fb0_row
	// clean the band to PoC: 0xb4000 bytes = 11520 cache lines (64 B)
	mov	x6, x5
	mov	x12, #11520
.Lc2s_m2_fb0_flush:
	dc	civac, x6
	add	x6, x6, #64
	subs	x12, x12, #1
	b.ne	.Lc2s_m2_fb0_flush

	movz	x5, #0xf980, lsl #16		// framebuffer 1: 0xf9800000
	add	x5, x5, x11
	mov	x8, x5
	mov	x12, x10
.Lc2s_m2_fb1_row:
	mov	x6, x8
	mov	x7, #360
.Lc2s_m2_fb1_col:
	stp	x4, x4, [x6], #16
	subs	x7, x7, #1
	b.ne	.Lc2s_m2_fb1_col
	add	x8, x8, x9
	subs	x12, x12, #1
	b.ne	.Lc2s_m2_fb1_row
	mov	x6, x5
	mov	x12, #11520
.Lc2s_m2_fb1_flush:
	dc	civac, x6
	add	x6, x6, #64
	subs	x12, x12, #1
	b.ne	.Lc2s_m2_fb1_flush

	movz	x5, #0xfac0, lsl #16		// framebuffer 2: 0xfac00000
	add	x5, x5, x11
	mov	x8, x5
	mov	x12, x10
.Lc2s_m2_fb2_row:
	mov	x6, x8
	mov	x7, #360
.Lc2s_m2_fb2_col:
	stp	x4, x4, [x6], #16
	subs	x7, x7, #1
	b.ne	.Lc2s_m2_fb2_col
	add	x8, x8, x9
	subs	x12, x12, #1
	b.ne	.Lc2s_m2_fb2_row
	mov	x6, x5
	mov	x12, #11520
.Lc2s_m2_fb2_flush:
	dc	civac, x6
	add	x6, x6, #64
	subs	x12, x12, #1
	b.ne	.Lc2s_m2_fb2_flush

	dsb	sy

	// Push the M2 band to the panel.  The MMU is on now, so the access
	// to 0x19050000 goes through the device mapping added in
	// create_init_idmap() (map_range.c); x4..x6 are reused and reloaded
	// by the init_task code right after.
	c2s_decon_refresh m2
#endif
	adr_l	x4, init_task
	init_cpu_task x4, x5, x6

	adr_l	x8, vectors			// load VBAR_EL1 with virtual
	msr	vbar_el1, x8			// vector table address
	isb

	stp	x29, x30, [sp, #-16]!
	mov	x29, sp

	str_l	x21, __fdt_pointer, x5		// Save FDT pointer

	adrp	x4, _text			// Save the offset between
	sub	x4, x4, x0			// the kernel virtual and
	str_l	x4, kimage_voffset, x5		// physical mappings

	mov	x0, x20
	bl	set_cpu_boot_mode_flag

#if defined(CONFIG_KASAN_GENERIC) || defined(CONFIG_KASAN_SW_TAGS)
	bl	kasan_early_init
#endif
	mov	x0, x20
	bl	finalise_el2			// Prefer VHE if possible
	ldp	x29, x30, [sp], #16
	bl	start_kernel
	ASM_BUG()
SYM_FUNC_END(__primary_switched)

/*
 * end early head section, begin head code that is also used for
 * hotplug and needs to have the same protections as the text region
 */
	.section ".idmap.text","a"

/*
 * Starting from EL2 or EL1, configure the CPU to execute at the highest
 * reachable EL supported by the kernel in a chosen default state. If dropping
 * from EL2 to EL1, configure EL2 before configuring EL1.
 *
 * Since we cannot always rely on ERET synchronizing writes to sysregs (e.g. if
 * SCTLR_ELx.EOS is clear), we place an ISB prior to ERET.
 *
 * Returns either BOOT_CPU_MODE_EL1 or BOOT_CPU_MODE_EL2 in x0 if
 * booted in EL1 or EL2 respectively, with the top 32 bits containing
 * potential context flags. These flags are *not* stored in __boot_cpu_mode.
 *
 * x0: whether we are being called from the primary boot path with the MMU on
 */
SYM_FUNC_START(init_kernel_el)
	mrs	x1, CurrentEL
	cmp	x1, #CurrentEL_EL2
	b.eq	init_el2

SYM_INNER_LABEL(init_el1, SYM_L_LOCAL)
	mov_q	x0, INIT_SCTLR_EL1_MMU_OFF
	pre_disable_mmu_workaround
	msr	sctlr_el1, x0
	isb
	mov_q	x0, INIT_PSTATE_EL1
	msr	spsr_el1, x0
	msr	elr_el1, lr
	mov	w0, #BOOT_CPU_MODE_EL1
	eret

SYM_INNER_LABEL(init_el2, SYM_L_LOCAL)
	msr	elr_el2, lr

	// clean all HYP code to the PoC if we booted at EL2 with the MMU on
	cbz	x0, 0f
	adrp	x0, __hyp_idmap_text_start
	adr_l	x1, __hyp_text_end
	adr_l	x2, dcache_clean_poc
	blr	x2

	mov_q	x0, INIT_SCTLR_EL2_MMU_OFF
	pre_disable_mmu_workaround
	msr	sctlr_el2, x0
	isb
0:

	init_el2_hcr	HCR_HOST_NVHE_FLAGS | HCR_ATA
	init_el2_state

	/* Hypervisor stub */
	adr_l	x0, __hyp_stub_vectors
	msr	vbar_el2, x0
	isb

	mov_q	x1, INIT_SCTLR_EL1_MMU_OFF

	mrs	x0, hcr_el2
	and	x0, x0, #HCR_E2H
	cbz	x0, 2f

	/* Set a sane SCTLR_EL1, the VHE way */
	msr_s	SYS_SCTLR_EL12, x1
	mov	x2, #BOOT_CPU_FLAG_E2H
	b	3f

2:
	msr	sctlr_el1, x1
	mov	x2, xzr
3:
	mov	x0, #INIT_PSTATE_EL1
	msr	spsr_el2, x0

	mov	w0, #BOOT_CPU_MODE_EL2
	orr	x0, x0, x2
	eret
SYM_FUNC_END(init_kernel_el)

	/*
	 * This provides a "holding pen" for platforms to hold all secondary
	 * cores are held until we're ready for them to initialise.
	 */
SYM_FUNC_START(secondary_holding_pen)
	mov	x0, xzr
	bl	init_kernel_el			// w0=cpu_boot_mode
	mrs	x2, mpidr_el1
	mov_q	x1, MPIDR_HWID_BITMASK
	and	x2, x2, x1
	adr_l	x3, secondary_holding_pen_release
pen:	ldr	x4, [x3]
	cmp	x4, x2
	b.eq	secondary_startup
	wfe
	b	pen
SYM_FUNC_END(secondary_holding_pen)

	/*
	 * Secondary entry point that jumps straight into the kernel. Only to
	 * be used where CPUs are brought online dynamically by the kernel.
	 */
SYM_FUNC_START(secondary_entry)
	mov	x0, xzr
	bl	init_kernel_el			// w0=cpu_boot_mode
	b	secondary_startup
SYM_FUNC_END(secondary_entry)

SYM_FUNC_START_LOCAL(secondary_startup)
	/*
	 * Common entry point for secondary CPUs.
	 */
	mov	x20, x0				// preserve boot mode

#ifdef CONFIG_ARM64_VA_BITS_52
alternative_if ARM64_HAS_VA52
	bl	__cpu_secondary_check52bitva
alternative_else_nop_endif
#endif

	bl	__cpu_setup			// initialise processor
	adrp	x1, swapper_pg_dir
	adrp	x2, idmap_pg_dir
	bl	__enable_mmu
	ldr	x8, =__secondary_switched
	br	x8
SYM_FUNC_END(secondary_startup)

	.text
SYM_FUNC_START_LOCAL(__secondary_switched)
	mov	x0, x20
	bl	set_cpu_boot_mode_flag

	mov	x0, x20
	bl	finalise_el2

	str_l	xzr, __early_cpu_boot_status, x3
	adr_l	x5, vectors
	msr	vbar_el1, x5
	isb

	adr_l	x0, secondary_data
	ldr	x2, [x0, #CPU_BOOT_TASK]
	cbz	x2, __secondary_too_slow

	init_cpu_task x2, x1, x3

#ifdef CONFIG_ARM64_PTR_AUTH
	ptrauth_keys_init_cpu x2, x3, x4, x5
#endif

	bl	secondary_start_kernel
	ASM_BUG()
SYM_FUNC_END(__secondary_switched)

SYM_FUNC_START_LOCAL(__secondary_too_slow)
	wfe
	wfi
	b	__secondary_too_slow
SYM_FUNC_END(__secondary_too_slow)

/*
 * Sets the __boot_cpu_mode flag depending on the CPU boot mode passed
 * in w0. See arch/arm64/include/asm/virt.h for more info.
 */
SYM_FUNC_START_LOCAL(set_cpu_boot_mode_flag)
	adr_l	x1, __boot_cpu_mode
	cmp	w0, #BOOT_CPU_MODE_EL2
	b.ne	1f
	add	x1, x1, #4
1:	str	w0, [x1]			// Save CPU boot mode
	ret
SYM_FUNC_END(set_cpu_boot_mode_flag)

/*
 * The booting CPU updates the failed status @__early_cpu_boot_status,
 * with MMU turned off.
 *
 * update_early_cpu_boot_status tmp, status
 *  - Corrupts tmp1, tmp2
 *  - Writes 'status' to __early_cpu_boot_status and makes sure
 *    it is committed to memory.
 */

	.macro	update_early_cpu_boot_status status, tmp1, tmp2
	mov	\tmp2, #\status
	adr_l	\tmp1, __early_cpu_boot_status
	str	\tmp2, [\tmp1]
	dmb	sy
	dc	ivac, \tmp1			// Invalidate potentially stale cache line
	.endm

/*
 * Enable the MMU.
 *
 *  x0  = SCTLR_EL1 value for turning on the MMU.
 *  x1  = TTBR1_EL1 value
 *  x2  = ID map root table address
 *
 * Returns to the caller via x30/lr. This requires the caller to be covered
 * by the .idmap.text section.
 *
 * Checks if the selected granule size is supported by the CPU.
 * If it isn't, park the CPU
 */
	.section ".idmap.text","a"
SYM_FUNC_START(__enable_mmu)
	mrs	x3, ID_AA64MMFR0_EL1
	ubfx	x3, x3, #ID_AA64MMFR0_EL1_TGRAN_SHIFT, 4
	cmp     x3, #ID_AA64MMFR0_EL1_TGRAN_SUPPORTED_MIN
	b.lt    __no_granule_support
	cmp     x3, #ID_AA64MMFR0_EL1_TGRAN_SUPPORTED_MAX
	b.gt    __no_granule_support
	phys_to_ttbr x2, x2
	msr	ttbr0_el1, x2			// load TTBR0
	load_ttbr1 x1, x1, x3

	set_sctlr_el1	x0

	ret
SYM_FUNC_END(__enable_mmu)

#ifdef CONFIG_ARM64_VA_BITS_52
SYM_FUNC_START(__cpu_secondary_check52bitva)
#ifndef CONFIG_ARM64_LPA2
	mrs_s	x0, SYS_ID_AA64MMFR2_EL1
	and	x0, x0, ID_AA64MMFR2_EL1_VARange_MASK
	cbnz	x0, 2f
#else
	mrs	x0, id_aa64mmfr0_el1
	sbfx	x0, x0, #ID_AA64MMFR0_EL1_TGRAN_SHIFT, 4
	cmp	x0, #ID_AA64MMFR0_EL1_TGRAN_LPA2
	b.ge	2f
#endif

	update_early_cpu_boot_status \
		CPU_STUCK_IN_KERNEL | CPU_STUCK_REASON_52_BIT_VA, x0, x1
1:	wfe
	wfi
	b	1b

2:	ret
SYM_FUNC_END(__cpu_secondary_check52bitva)
#endif

SYM_FUNC_START_LOCAL(__no_granule_support)
	/* Indicate that this CPU can't boot and is stuck in the kernel */
	update_early_cpu_boot_status \
		CPU_STUCK_IN_KERNEL | CPU_STUCK_REASON_NO_GRAN, x1, x2
1:
	wfe
	wfi
	b	1b
SYM_FUNC_END(__no_granule_support)

SYM_FUNC_START_LOCAL(__primary_switch)
	adrp	x1, reserved_pg_dir
	adrp	x2, __pi_init_idmap_pg_dir
	bl	__enable_mmu

	adrp	x1, early_init_stack
	mov	sp, x1
	mov	x29, xzr
	mov	x0, x20				// pass the full boot status
	mov	x1, x21				// pass the FDT
	bl	__pi_early_map_kernel		// Map and relocate the kernel

	ldr	x8, =__primary_switched
	adrp	x0, KERNEL_START		// __pa(KERNEL_START)
	br	x8
SYM_FUNC_END(__primary_switch)
