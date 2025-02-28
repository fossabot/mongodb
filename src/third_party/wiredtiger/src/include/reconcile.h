/*-
 * Copyright (c) 2014-2019 MongoDB, Inc.
 * Copyright (c) 2008-2014 WiredTiger, Inc.
 *	All rights reserved.
 *
 * See the file LICENSE for redistribution information.
 */

#include "wt_internal.h"

/*
 * Reconciliation is the process of taking an in-memory page, walking each entry
 * in the page, building a backing disk image in a temporary buffer representing
 * that information, and writing that buffer to disk.  What could be simpler?
 *
 * WT_RECONCILE --
 *	Information tracking a single page reconciliation.
 */
typedef struct {
	WT_REF  *ref;			/* Page being reconciled */
	WT_PAGE *page;
	uint32_t flags;			/* Caller's configuration */

	/*
	 * Track start/stop write generation to decide if all changes to the
	 * page are written.
	 */
	uint32_t orig_write_gen;

	/*
	 * Track start/stop checkpoint generations to decide if lookaside table
	 * records are correct.
	 */
	uint64_t orig_btree_checkpoint_gen;
	uint64_t orig_txn_checkpoint_gen;

	/*
	 * Track the oldest running transaction and whether to skew lookaside
	 * to the newest update.
	 */
	bool las_skew_newest;
	uint64_t last_running;

	/* Track the page's min/maximum transactions. */
	uint64_t max_txn;
	wt_timestamp_t max_timestamp;

	/* Lookaside boundary tracking. */
	uint64_t unstable_txn;
	wt_timestamp_t unstable_timestamp;

	u_int updates_seen;		/* Count of updates seen. */
	u_int updates_unstable;		/* Count of updates not visible_all. */

	bool update_uncommitted;	/* An update was uncommitted */
	bool update_used;		/* An update could be used */

	/*
	 * When we can't mark the page clean (for example, checkpoint found some
	 * uncommitted updates), there's a leave-dirty flag.
	 */
	bool leave_dirty;

	/*
	 * Track if reconciliation has seen any overflow items.  If a leaf page
	 * with no overflow items is written, the parent page's address cell is
	 * set to the leaf-no-overflow type.  This means we can delete the leaf
	 * page without reading it because we don't have to discard any overflow
	 * items it might reference.
	 *
	 * The test test is per-page reconciliation, that is, once we see an
	 * overflow item on the page, all subsequent leaf pages written for the
	 * page will not be leaf-no-overflow type, regardless of whether or not
	 * they contain overflow items.  In other words, leaf-no-overflow is not
	 * guaranteed to be set on every page that doesn't contain an overflow
	 * item, only that if it is set, the page contains no overflow items.
	 * XXX
	 * This was originally done because raw compression couldn't do better,
	 * now that raw compression has been removed, we should do better.
	 */
	bool	ovfl_items;

	/*
	 * Track if reconciliation of a row-store leaf page has seen empty (zero
	 * length) values.  We don't write out anything for empty values, so if
	 * there are empty values on a page, we have to make two passes over the
	 * page when it's read to figure out how many keys it has, expensive in
	 * the common case of no empty values and (entries / 2) keys.  Likewise,
	 * a page with only empty values is another common data set, and keys on
	 * that page will be equal to the number of entries.  In both cases, set
	 * a flag in the page's on-disk header.
	 *
	 * The test is per-page reconciliation as described above for the
	 * overflow-item test.
	 */
	bool	all_empty_value, any_empty_value;

	/*
	 * Reconciliation gets tricky if we have to split a page, which happens
	 * when the disk image we create exceeds the page type's maximum disk
	 * image size.
	 *
	 * First, the target size of the page we're building.
	 */
	uint32_t page_size;		/* Page size */

	/*
	 * Second, the split size: if we're doing the page layout, split to a
	 * smaller-than-maximum page size when a split is required so we don't
	 * repeatedly split a packed page.
	 */
	uint32_t split_size;		/* Split page size */
	uint32_t min_split_size;	/* Minimum split page size */

	/*
	 * We maintain two split chunks in the memory during reconciliation to
	 * be written out as pages. As we get to the end of the data, if the
	 * last one turns out to be smaller than the minimum split size, we go
	 * back into the penultimate chunk and split at this minimum split size
	 * boundary. This moves some data from the penultimate chunk to the last
	 * chunk, hence increasing the size of the last page written without
	 * decreasing the penultimate page size beyond the minimum split size.
	 * For this reason, we maintain an expected split percentage boundary
	 * and a minimum split percentage boundary.
	 *
	 * Chunks are referenced by current and previous pointers. In case of a
	 * split, previous references the first chunk and current switches to
	 * the second chunk. If reconciliation generates more split chunks, the
	 * the previous chunk is written to the disk and current and previous
	 * swap.
	 */
	struct __wt_rec_chunk {
		/*
		 * The recno and entries fields are the starting record number
		 * of the split chunk (for column-store splits), and the number
		 * of entries in the split chunk.
		 *
		 * The key for a row-store page; no column-store key is needed
		 * because the page's recno, stored in the recno field, is the
		 * column-store key.
		 */
		uint32_t entries;
		uint64_t recno;
		WT_ITEM  key;

		uint32_t min_entries;
		uint64_t min_recno;
		WT_ITEM  min_key;

		/* Minimum split-size boundary buffer offset. */
		size_t   min_offset;

		WT_ITEM image;				/* disk-image */
	} chunkA, chunkB, *cur_ptr, *prev_ptr;

	/*
	 * We track current information about the current record number, the
	 * number of entries copied into the disk image buffer, where we are
	 * in the buffer, and how much memory remains. Those values are
	 * packaged here rather than passing pointers to stack locations
	 * around the code.
	 */
	uint64_t recno;			/* Current record number */
	uint32_t entries;		/* Current number of entries */
	uint8_t *first_free;		/* Current first free byte */
	size_t	 space_avail;		/* Remaining space in this chunk */
	/* Remaining space in this chunk to put a minimum size boundary */
	size_t	 min_space_avail;

	/*
	 * Saved update list, supporting the WT_REC_UPDATE_RESTORE and
	 * WT_REC_LOOKASIDE configurations. While reviewing updates for each
	 * page, we save WT_UPDATE lists here, and then move them to per-block
	 * areas as the blocks are defined.
	 */
	WT_SAVE_UPD *supd;		/* Saved updates */
	uint32_t     supd_next;
	size_t	     supd_allocated;
	size_t       supd_memsize;	/* Size of saved update structures */

	/* List of pages we've written so far. */
	WT_MULTI *multi;
	uint32_t  multi_next;
	size_t	  multi_allocated;

	/*
	 * Root pages are written when wrapping up the reconciliation, remember
	 * the image we're going to write.
	 */
	WT_ITEM *wrapup_checkpoint;
	bool	 wrapup_checkpoint_compressed;

	/*
	 * We don't need to keep the 0th key around on internal pages, the
	 * search code ignores them as nothing can sort less by definition.
	 * There's some trickiness here, see the code for comments on how
	 * these fields work.
	 */
	bool	cell_zero;		/* Row-store internal page 0th key */

	/*
	 * We calculate checksums to find previously written identical blocks,
	 * but once a match fails during an eviction, there's no point trying
	 * again.
	 */
	bool	evict_matching_checksum_failed;

	/*
	 * WT_REC_DICTIONARY --
	 *	We optionally build a dictionary of values for leaf pages. Where
	 * two value cells are identical, only write the value once, the second
	 * and subsequent copies point to the original cell. The dictionary is
	 * fixed size, but organized in a skip-list to make searches faster.
	 */
	struct __wt_rec_dictionary {
		uint64_t hash;				/* Hash value */
		uint32_t offset;			/* Matching cell */

		u_int depth;				/* Skiplist */
		WT_REC_DICTIONARY *next[0];
	} **dictionary;					/* Dictionary */
	u_int dictionary_next, dictionary_slots;	/* Next, max entries */
							/* Skiplist head. */
	WT_REC_DICTIONARY *dictionary_head[WT_SKIP_MAXDEPTH];

	/*
	 * WT_REC_KV--
	 *	An on-page key/value item we're building.
	 */
	struct __wt_rec_kv {
		WT_ITEM	 buf;		/* Data */
		WT_CELL	 cell;		/* Cell and cell's length */
		size_t cell_len;
		size_t len;		/* Total length of cell + data */
	} k, v;				/* Key/Value being built */

	WT_ITEM *cur, _cur;		/* Key/Value being built */
	WT_ITEM *last, _last;		/* Last key/value built */

	bool key_pfx_compress;		/* If can prefix-compress next key */
	bool key_pfx_compress_conf;	/* If prefix compression configured */
	bool key_sfx_compress;		/* If can suffix-compress next key */
	bool key_sfx_compress_conf;	/* If suffix compression configured */

	bool is_bulk_load;		/* If it's a bulk load */

	WT_SALVAGE_COOKIE *salvage;	/* If it's a salvage operation */

	bool cache_write_lookaside;	/* Used the lookaside table */
	bool cache_write_restore;	/* Used update/restoration */

	uint32_t tested_ref_state;	/* Debugging information */

	/*
	 * XXX
	 * In the case of a modified update, we may need a copy of the current
	 * value as a set of bytes. We call back into the btree code using a
	 * fake cursor to do that work. This a layering violation and fragile,
	 * we need a better solution.
	 */
	WT_CURSOR_BTREE update_modify_cbt;
} WT_RECONCILE;

/*
 * WT_CHILD_RELEASE, WT_CHILD_RELEASE_ERR --
 *	Macros to clean up during internal-page reconciliation, releasing the
 *	hazard pointer we're holding on child pages.
 */
#define	WT_CHILD_RELEASE(session, hazard, ref) do {			\
	if (hazard) {							\
		(hazard) = false;					\
		WT_TRET(						\
		    __wt_page_release(session, ref, WT_READ_NO_EVICT));	\
	}								\
} while (0)
#define	WT_CHILD_RELEASE_ERR(session, hazard, ref) do {			\
	WT_CHILD_RELEASE(session, hazard, ref);				\
	WT_ERR(ret);							\
} while (0)

typedef enum {
    WT_CHILD_IGNORE,				/* Ignored child */
    WT_CHILD_MODIFIED,				/* Modified child */
    WT_CHILD_ORIGINAL,				/* Original child */
    WT_CHILD_PROXY				/* Deleted child: proxy */
} WT_CHILD_STATE;

/*
 * Macros from fixed-length entries to/from bytes.
 */
#define	WT_FIX_BYTES_TO_ENTRIES(btree, bytes)				\
    ((uint32_t)((((bytes) * 8) / (btree)->bitcnt)))
#define	WT_FIX_ENTRIES_TO_BYTES(btree, entries)				\
	((uint32_t)WT_ALIGN((entries) * (btree)->bitcnt, 8))
