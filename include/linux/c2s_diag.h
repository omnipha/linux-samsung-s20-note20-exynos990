/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __LINUX_C2S_DIAG_H
#define __LINUX_C2S_DIAG_H

#include <linux/init.h>
#include <linux/types.h>

#ifdef CONFIG_C2S_DIAG

/*
 * Paint one milestone band (128 rows x 1440 px, a8r8g8b8) into the splash
 * framebuffers and push it to the panel with a DECON0 shadow update.
 *
 * c2s_band_early() must only be called from __init code that runs before
 * free_initmem(): it reaches the framebuffers through the boot-time ID map
 * (while memstart_addr still holds its -1 sentinel) and afterwards through
 * early_memremap()/early_ioremap(), both of which live in .init.text and
 * are freed together with it.  Calling it from .text is a section mismatch.
 *
 * c2s_late_init() must run once, from process context, after mm_core_init()
 * (vmap and slab are up): it takes the long-lived mappings c2s_band() uses -
 * ioremap_wc(), the same write-combining alias simplefb maps fb0 with.
 *
 * c2s_band() then allocates nothing and never sleeps - fill, cache clean,
 * DECON kick - so it is callable from atomic context (interrupts/BH
 * disabled, spinlock held) as well as from initcalls and run_init_process().
 * It is a no-op until c2s_late_init() has run.
 *
 * c2s_scanout_probe() paints one band with a *different* colour per splash
 * buffer, so a single photo of the panel names the buffer the DECON scans
 * out: red = fb0, green = fb1, blue = fb2.  It runs in the boot ID-map
 * phase, where all three buffers are identity-mapped.
 *
 * The two markers below publish mapping-lifetime transitions inside
 * setup_arch().  They exist because no usable global distinguishes them:
 * memstart_addr still holds its -1 sentinel after cpu_uninstall_idmap(),
 * so it cannot say "the ID map is gone", and it becomes valid one call
 * before paging_init(), so it cannot say "the linear map exists".  Reading
 * a physical framebuffer through the wrong alias faults, so each phase
 * announces itself explicitly and c2s_band_early() refuses to take the
 * phys_to_virt() branch until the second marker has run.
 *
 *   c2s_mark_idmap_gone()    call immediately after cpu_uninstall_idmap().
 *   c2s_mark_linear_ready()  call immediately after paging_init().
 */
void __init c2s_band_early(u32 row, u32 colour);
void __init c2s_scanout_probe(u32 row, u32 c_fb0, u32 c_fb1, u32 c_fb2);
void __init c2s_mark_idmap_gone(void);
void __init c2s_mark_linear_ready(void);
void __init c2s_late_init(void);
void c2s_band(u32 row, u32 colour);

#else /* CONFIG_C2S_DIAG */

static inline void c2s_band_early(u32 row, u32 colour) { }
static inline void c2s_scanout_probe(u32 row, u32 c_fb0, u32 c_fb1,
				     u32 c_fb2) { }
static inline void c2s_mark_idmap_gone(void) { }
static inline void c2s_mark_linear_ready(void) { }
static inline void c2s_late_init(void) { }
static inline void c2s_band(u32 row, u32 colour) { }

#endif /* CONFIG_C2S_DIAG */

#endif /* __LINUX_C2S_DIAG_H */
