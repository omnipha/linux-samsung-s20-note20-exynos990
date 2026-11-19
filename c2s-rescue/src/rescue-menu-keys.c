/* SPDX-License-Identifier: GPL-2.0 */
/*
 * rescue-menu-keys - input front end for the c2s rescue boot menu.
 *
 * Reads gpio-keys evdev devices and the USB ACM serial line *simultaneously*
 * from one persistent poll loop, so no event can be lost between reader
 * restarts. The previous shell implementation reopened the evdev node for
 * every single read; evdev only queues events for clients that have the
 * device open, so everything that arrived between two reads was lost - the
 * keys simply appeared to be dead.
 *
 * Selection (first match wins, feedback is printed for every decision):
 *   EV_KEY press 114 (KEY_VOLUMEDOWN)   -> telnet
 *   EV_KEY press 115 (KEY_VOLUMEUP)     -> rescue
 *   EV_KEY press 116 (KEY_POWER)        -> rescue
 *   serial line "telnet" + Enter        -> telnet
 *   serial line "rescue"/"ssh"/Enter    -> rescue
 *   nothing within the timeout          -> rescue (telnet stays OFF)
 *
 * The serial selection is line based on purpose: a single character would
 * be triggered by the echo of the menu text a terminal sends back ("telnet"
 * contains a 't'), while a whole line can never be produced by the mirrored
 * menu. Lines that are neither "telnet" nor "rescue"/"ssh" are ignored.
 *
 * EV_KEY release (value 0), autorepeat (value 2) and every other event
 * type or key code are ignored. Events are consumed in 24-byte struct
 * input_event chunks (arm64: 2x64-bit timeval + u16 type + u16 code +
 * s32 value).
 *
 * The serial line is put into raw, no-echo mode while the menu is open
 * (tcsetattr) and only this process reads it, so the device side never
 * echoes anything back into the input path.
 *
 * stdout carries exactly one line: the selected mode ("rescue" or "telnet").
 * All diagnostics go to stderr and, when writable, to /dev/console so the
 * operator sees the decision on the phone screen.
 *
 * Host-testable: device paths may be regular files, fifos or sockets;
 * termios is only touched on real ttys (isatty()). Run the aarch64 binary
 * under qemu-aarch64 in scripts/verify.sh.
 *
 * Usage:
 *   rescue-menu-keys [--timeout SEC] [--drain SEC] [--tty DEV] DEV...
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define MAX_FDS 64
#define MAX_LINE 128

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void feedback(const char *msg)
{
	fprintf(stderr, "rescue-menu: %s\n", msg);
	fflush(stderr);
	/* mirror to the on-screen console when it is writable */
	if (access("/dev/console", W_OK) == 0) {
		FILE *c = fopen("/dev/console", "w");
		if (c) {
			fprintf(c, "rescue-menu: %s\n", msg);
			fclose(c);
		}
	}
}

/* trim in place, return the trimmed string */
static char *trim(char *s)
{
	size_t n;
	char *p = s;
	while (*p == ' ' || *p == '\t')
		p++;
	n = strlen(p);
	while (n > 0 && (p[n - 1] == ' ' || p[n - 1] == '\t' ||
			 p[n - 1] == '\r' || p[n - 1] == '\n'))
		n--;
	p[n] = '\0';
	return p;
}

static int line_is(const char *line, const char *word)
{
	size_t i;
	if (strlen(line) != strlen(word))
		return 0;
	for (i = 0; word[i]; i++) {
		if (tolower((unsigned char)line[i]) !=
		    tolower((unsigned char)word[i]))
			return 0;
	}
	return 1;
}

int main(int argc, char **argv)
{
	double timeout = 30.0, drain = 0.4;
	const char *evdevs[MAX_FDS];
	const char *ttys[MAX_FDS];
	int nev = 0, ntt = 0, nfds = 0;
	int i, argi;

	for (argi = 1; argi < argc; argi++) {
		const char *a = argv[argi];
		if (!strcmp(a, "--timeout") && argi + 1 < argc) {
			timeout = atof(argv[++argi]);
		} else if (!strcmp(a, "--drain") && argi + 1 < argc) {
			drain = atof(argv[++argi]);
		} else if (!strcmp(a, "--tty") && argi + 1 < argc) {
			if (ntt < MAX_FDS)
				ttys[ntt++] = argv[++argi];
		} else if (a[0] == '-' && a[1]) {
			fprintf(stderr, "rescue-menu-keys: unknown option %s\n", a);
			return 2;
		} else if (nev < MAX_FDS) {
			evdevs[nev++] = a;
		}
	}
	if (timeout <= 0)
		timeout = 30.0;
	if (drain < 0)
		drain = 0;

	struct pollfd pfd[MAX_FDS];
	char kind[MAX_FDS]; /* 'e' = evdev, 't' = tty */
	struct termios saved[MAX_FDS];
	int have_tc[MAX_FDS];

	char banner[512];
	int banner_len;

	banner_len = snprintf(banner, sizeof(banner),
		"c2s rescue boot menu (timeout %.0fs)\r\n"
		"  vol-up / power / enter : rescue  (USB SSH, key only)\r\n"
		"  vol-down or type telnet : rescue + USB telnet (DEBUG)\r\n"
		"  timeout                 : rescue  (telnet off)\r\n",
		timeout);
	if (banner_len < 0)
		banner_len = 0;
	if (banner_len >= (int)sizeof(banner))
		banner_len = (int)sizeof(banner) - 1;

	for (i = 0; i < ntt && nfds < MAX_FDS; i++) {
		int fd = open(ttys[i], O_RDWR | O_NONBLOCK);
		if (fd < 0)
			fd = open(ttys[i], O_RDONLY | O_NONBLOCK);
		if (fd < 0) {
			fprintf(stderr, "rescue-menu-keys: tty %s: %s\n",
				ttys[i], strerror(errno));
			continue;
		}
		have_tc[nfds] = 0;
		if (isatty(fd)) {
			struct termios t;
			if (tcgetattr(fd, &t) == 0) {
				saved[nfds] = t;
				/* raw, no echo: nothing the terminal mirrors
				 * back may look like a selection */
				cfmakeraw(&t);
				t.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG);
				tcsetattr(fd, TCSANOW, &t);
				tcflush(fd, TCIFLUSH);
				have_tc[nfds] = 1;
			}
			/* Show the menu on the serial line as well. A terminal
			 * with local echo sends this text back to us; the
			 * line based matching below ignores it because the
			 * echoed line is not "telnet"/"rescue". */
			if (write(fd, banner, banner_len) < 0) {
				/* not fatal: banner is a nicety */
			}
		}
		pfd[nfds].fd = fd;
		pfd[nfds].events = POLLIN;
		kind[nfds] = 't';
		nfds++;
	}
	for (i = 0; i < nev && nfds < MAX_FDS; i++) {
		int fd = open(evdevs[i], O_RDONLY | O_NONBLOCK);
		if (fd < 0) {
			fprintf(stderr, "rescue-menu-keys: evdev %s: %s\n",
				evdevs[i], strerror(errno));
			continue;
		}
		pfd[nfds].fd = fd;
		pfd[nfds].events = POLLIN;
		kind[nfds] = 'e';
		nfds++;
	}
	if (nfds == 0) {
		feedback("no input device could be opened; default rescue");
		printf("rescue\n");
		return 0;
	}

	double start = now_s();
	double drain_end = start + drain;
	double deadline = start + timeout;
	const char *mode = NULL;
	char line[MAX_LINE];
	int line_len = 0;

	while (!mode) {
		double left = deadline - now_s();
		if (left <= 0)
			break;
		int wait_ms = (int)(left * 1000.0) + 1;
		if (wait_ms > 250)
			wait_ms = 250; /* bounded, so a POLLHUP fd cannot spin */
		int r = poll(pfd, nfds, wait_ms);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (r == 0)
			continue;
		for (i = 0; i < nfds && !mode; i++) {
			if (pfd[i].revents & (POLLHUP | POLLERR | POLLNVAL)) {
				/* no writer/data left: keep the fd open (a
				 * fifo writer may show up later) but do not
				 * spin on it */
				if (!(pfd[i].revents & POLLIN)) {
					usleep(50000);
					continue;
				}
			}
			if (!(pfd[i].revents & POLLIN))
				continue;
			if (kind[i] == 'e') {
				struct input_event ev[64];
				ssize_t n;
				while (!mode &&
				       (n = read(pfd[i].fd, ev, sizeof(ev))) > 0) {
					size_t off;
					/* walk the buffer by byte offset: ev[k]
					 * would treat k as an element index */
					for (off = 0;
					     off + sizeof(ev[0]) <= (size_t)n;
					     off += sizeof(ev[0])) {
						struct input_event *e =
							(struct input_event *)
							((char *)ev + off);
						if (e->type != EV_KEY)
							continue;
						if (e->value != 1)
							continue; /* release/repeat */
						if (e->code == 114) {
							mode = "telnet";
							feedback("volume down -> telnet (USB only, explicit)");
						} else if (e->code == 115) {
							mode = "rescue";
							feedback("volume up -> rescue (SSH, telnet off)");
						} else if (e->code == 116) {
							mode = "rescue";
							feedback("power -> rescue (SSH, telnet off)");
						}
						if (mode)
							break;
					}
				}
			} else {
				char buf[256];
				ssize_t n;
				while (!mode &&
				       (n = read(pfd[i].fd, buf, sizeof(buf))) > 0) {
					ssize_t k;
					for (k = 0; k < n && !mode; k++) {
						char c = buf[k];
						if (c == '\r' || c == '\n') {
							char *cmd;
							line[line_len] = '\0';
							cmd = trim(line);
							line_len = 0;
							if (now_s() < drain_end)
								continue; /* echo of our menu */
							if (line_is(cmd, "telnet")) {
								mode = "telnet";
								feedback("serial 'telnet' -> telnet (USB only, explicit)");
							} else if (line_is(cmd, "rescue") ||
								   line_is(cmd, "ssh") ||
								   cmd[0] == '\0') {
								mode = "rescue";
								feedback("serial enter -> rescue (SSH, telnet off)");
							} else {
								char msg[160];
								snprintf(msg, sizeof(msg),
									"serial line '%s' ignored", cmd);
								feedback(msg);
							}
							if (mode)
								break;
							continue;
						}
						if (line_len < (int)sizeof(line) - 1)
							line[line_len++] = c;
					}
				}
			}
		}
	}

	for (i = 0; i < nfds; i++) {
		if (have_tc[i])
			tcsetattr(pfd[i].fd, TCSANOW, &saved[i]);
		close(pfd[i].fd);
	}

	if (!mode) {
		mode = "rescue";
		feedback("timeout; default rescue (telnet off)");
	}
	printf("%s\n", mode);
	return 0;
}
