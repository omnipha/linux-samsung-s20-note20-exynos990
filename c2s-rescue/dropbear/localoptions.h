/* Local build options for the c2s rescue initramfs dropbear.
 *
 * Password and PAM authentication are disabled at compile time: the rescue
 * image accepts only the operator's authorized public host key.
 *
 * DROPBEAR_SVR_MULTIUSER must stay enabled: with it disabled, dropbear
 * aborts with "Not a multiuser system" (common-session.c calls
 * getgroups() and expects ENOSYS).
 */
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PAM_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH 1
#define DROPBEAR_SVR_MULTIUSER 1
#define DROPBEAR_SMALL_CODE 1
#define DROPBEAR_SVR_LOCALTCPFWD 0
