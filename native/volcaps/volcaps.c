// volcaps prints the capabilities a volume reports to the kernel, one per
// line, as "fmt.NAME=yes", "int.NAME=no", and so on.
//
// This is a test tool rather than part of the file system. It exists because
// the capabilities a volume claims are invisible to every operation an
// ordinary test performs: a mount that wrongly reported no symbolic links and
// no hard links passed the installed test suite and shipped, because symlink
// and hardlink operations still worked. Only getattrlist can see the claim.
//
// A capability the volume did not mark valid prints "=unclaimed" rather than
// "=no": the kernel reports the bit as clear either way, but the two mean
// different things, and a test asserting "no" should not be satisfied by a
// volume that never answered.
//
// Build: cc -o volcaps native/volcaps/volcaps.c
// Usage: volcaps MOUNTPOINT
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <unistd.h>

struct volattrs {
	uint32_t length;
	vol_capabilities_attr_t caps;
} __attribute__((aligned(4), packed));

static void show(const char *class, const char *name, uint32_t valid, uint32_t cap, uint32_t bit) {
	const char *state = "unclaimed";
	if (valid & bit)
		state = (cap & bit) ? "yes" : "no";
	printf("%s.%s=%s\n", class, name, state);
}

int main(int argc, char **argv) {
	struct attrlist al;
	struct volattrs out;

	if (argc != 2) {
		fprintf(stderr, "usage: volcaps MOUNTPOINT\n");
		return 2;
	}

	memset(&al, 0, sizeof(al));
	al.bitmapcount = ATTR_BIT_MAP_COUNT;
	al.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES;

	if (getattrlist(argv[1], &al, &out, sizeof(out), 0) != 0) {
		perror("getattrlist");
		return 1;
	}

	uint32_t valid = out.caps.valid[VOL_CAPABILITIES_FORMAT];
	uint32_t cap = out.caps.capabilities[VOL_CAPABILITIES_FORMAT];
	show("fmt", "PERSISTENTOBJECTIDS", valid, cap, VOL_CAP_FMT_PERSISTENTOBJECTIDS);
	show("fmt", "DOCUMENT_ID", valid, cap, VOL_CAP_FMT_DOCUMENT_ID);
	show("fmt", "SYMBOLICLINKS", valid, cap, VOL_CAP_FMT_SYMBOLICLINKS);
	show("fmt", "HARDLINKS", valid, cap, VOL_CAP_FMT_HARDLINKS);
	show("fmt", "SPARSE_FILES", valid, cap, VOL_CAP_FMT_SPARSE_FILES);
	show("fmt", "HIDDEN_FILES", valid, cap, VOL_CAP_FMT_HIDDEN_FILES);
	show("fmt", "64BIT_OBJECT_IDS", valid, cap, VOL_CAP_FMT_64BIT_OBJECT_IDS);
	show("fmt", "NO_VOLUME_SIZES", valid, cap, VOL_CAP_FMT_NO_VOLUME_SIZES);
	show("fmt", "CASE_SENSITIVE", valid, cap, VOL_CAP_FMT_CASE_SENSITIVE);

	uint32_t ivalid = out.caps.valid[VOL_CAPABILITIES_INTERFACES];
	uint32_t icap = out.caps.capabilities[VOL_CAPABILITIES_INTERFACES];
	show("int", "EXTENDED_ATTR", ivalid, icap, VOL_CAP_INT_EXTENDED_ATTR);
	show("int", "NAMEDSTREAMS", ivalid, icap, VOL_CAP_INT_NAMEDSTREAMS);
	show("int", "EXCHANGEDATA", ivalid, icap, VOL_CAP_INT_EXCHANGEDATA);
	show("int", "RENAME_SWAP", ivalid, icap, VOL_CAP_INT_RENAME_SWAP);
	show("int", "RENAME_EXCL", ivalid, icap, VOL_CAP_INT_RENAME_EXCL);
	show("int", "ADVLOCK", ivalid, icap, VOL_CAP_INT_ADVLOCK);
	show("int", "FLOCK", ivalid, icap, VOL_CAP_INT_FLOCK);
	show("int", "ATTRLIST", ivalid, icap, VOL_CAP_INT_ATTRLIST);
	return 0;
}
