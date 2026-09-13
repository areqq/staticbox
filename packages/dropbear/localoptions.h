/* localoptions.h -- staticbox's Dropbear build options.
 *
 * Deliberately minimal: everything not named here keeps Dropbear's own
 * default, so this is a stock client and server rather than a tailored one.
 *
 * Post-quantum key exchange is the one thing turned off, and only for size.
 * mlkem768 and sntrup761 cost about 67 KB together -- a tenth of the binary on
 * mipsel -- and what they buy is protection against traffic recorded today
 * being decrypted years from now. On a set-top box reached over a LAN that is
 * not the threat worth 67 KB of flash. curve25519-sha256 is negotiated
 * instead, which OpenSSH has offered since 6.5 (2014).
 */

#define DROPBEAR_MLKEM768   0
#define DROPBEAR_SNTRUP761  0
