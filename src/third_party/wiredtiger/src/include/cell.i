/*-
 * Copyright (c) 2014-2019 MongoDB, Inc.
 * Copyright (c) 2008-2014 WiredTiger, Inc.
 *	All rights reserved.
 *
 * See the file LICENSE for redistribution information.
 */

/*
 * WT_CELL_FOREACH --
 *	Walk the cells on a page.
 */
#define	WT_CELL_FOREACH(btree, dsk, cell, unpack, i)			\
	for ((cell) =							\
	    WT_PAGE_HEADER_BYTE(btree, dsk), (i) = (dsk)->u.entries;	\
	    (i) > 0;							\
	    (cell) = (WT_CELL *)((uint8_t *)(cell) + (unpack)->__len), --(i))

/*
 * __wt_cell_pack_addr --
 *	Pack an address cell.
 */
static inline size_t
__wt_cell_pack_addr(WT_CELL *cell, u_int cell_type, uint64_t recno, size_t size)
{
	uint8_t *p;

	p = cell->__chunk + 1;

	if (recno == WT_RECNO_OOB)
		cell->__chunk[0] = (uint8_t)cell_type;	/* Type */
	else {
		cell->__chunk[0] = (uint8_t)(cell_type | WT_CELL_64V);
		(void)__wt_vpack_uint(&p, 0, recno);	/* Record number */
	}
	(void)__wt_vpack_uint(&p, 0, (uint64_t)size);	/* Length */
	return (WT_PTRDIFF(p, cell));
}

/*
 * __wt_cell_pack_data --
 *	Set a data item's WT_CELL contents.
 */
static inline size_t
__wt_cell_pack_data(WT_CELL *cell, uint64_t rle, size_t size)
{
	uint8_t byte, *p;

	/*
	 * Short data cells without run-length encoding have 6 bits of data
	 * length in the descriptor byte.
	 */
	if (rle < 2 && size <= WT_CELL_SHORT_MAX) {
		byte = (uint8_t)size;			/* Type + length */
		cell->__chunk[0] = (uint8_t)
		    ((byte << WT_CELL_SHORT_SHIFT) | WT_CELL_VALUE_SHORT);
		return (1);
	}

	p = cell->__chunk + 1;
	if (rle < 2) {
		size -= WT_CELL_SIZE_ADJUST;
		cell->__chunk[0] = WT_CELL_VALUE;	/* Type */
	} else {
		cell->__chunk[0] = WT_CELL_VALUE | WT_CELL_64V;
		(void)__wt_vpack_uint(&p, 0, rle);	/* RLE */
	}
	(void)__wt_vpack_uint(&p, 0, (uint64_t)size);	/* Length */
	return (WT_PTRDIFF(p, cell));
}

/*
 * __wt_cell_pack_data_match --
 *	Return if two items would have identical WT_CELLs (except for any RLE).
 */
static inline int
__wt_cell_pack_data_match(
    WT_CELL *page_cell, WT_CELL *val_cell, const uint8_t *val_data,
    bool *matchp)
{
	uint64_t av, bv;
	const uint8_t *a, *b;
	bool rle;

	*matchp = 0;				/* Default to no-match */

	/*
	 * This is a special-purpose function used by reconciliation to support
	 * dictionary lookups.  We're passed an on-page cell and a created cell
	 * plus a chunk of data we're about to write on the page, and we return
	 * if they would match on the page.  The column-store comparison ignores
	 * the RLE because the copied cell will have its own RLE.
	 */
	a = (uint8_t *)page_cell;
	b = (uint8_t *)val_cell;

	if (WT_CELL_SHORT_TYPE(a[0]) == WT_CELL_VALUE_SHORT) {
		av = a[0] >> WT_CELL_SHORT_SHIFT;
		++a;
	} else if (WT_CELL_TYPE(a[0]) == WT_CELL_VALUE) {
		rle = (a[0] & WT_CELL_64V) != 0;	/* Skip any RLE */
		++a;
		if (rle)
			WT_RET(__wt_vunpack_uint(&a, 0, &av));
		WT_RET(__wt_vunpack_uint(&a, 0, &av));	/* Length */
	} else
		return (0);

	if (WT_CELL_SHORT_TYPE(b[0]) == WT_CELL_VALUE_SHORT) {
		bv = b[0] >> WT_CELL_SHORT_SHIFT;
		++b;
	} else if (WT_CELL_TYPE(b[0]) == WT_CELL_VALUE) {
		rle = (b[0] & WT_CELL_64V) != 0;	/* Skip any RLE */
		++b;
		if (rle)
			WT_RET(__wt_vunpack_uint(&b, 0, &bv));
		WT_RET(__wt_vunpack_uint(&b, 0, &bv));	/* Length */
	} else
		return (0);

	if (av == bv)
		*matchp = memcmp(a, val_data, av) == 0;
	return (0);
}

/*
 * __wt_cell_pack_copy --
 *	Write a copy value cell.
 */
static inline size_t
__wt_cell_pack_copy(WT_CELL *cell, uint64_t rle, uint64_t v)
{
	uint8_t *p;

	p = cell->__chunk + 1;

	if (rle < 2)					/* Type */
		cell->__chunk[0] = WT_CELL_VALUE_COPY;
	else {						/* Type */
		cell->__chunk[0] = WT_CELL_VALUE_COPY | WT_CELL_64V;
		(void)__wt_vpack_uint(&p, 0, rle);	/* RLE */
	}
	(void)__wt_vpack_uint(&p, 0, v);		/* Copy offset */
	return (WT_PTRDIFF(p, cell));
}

/*
 * __wt_cell_pack_del --
 *	Write a deleted value cell.
 */
static inline size_t
__wt_cell_pack_del(WT_CELL *cell, uint64_t rle)
{
	uint8_t *p;

	p = cell->__chunk + 1;
	if (rle < 2) {					/* Type */
		cell->__chunk[0] = WT_CELL_DEL;
		return (1);
	}
							/* Type */
	cell->__chunk[0] = WT_CELL_DEL | WT_CELL_64V;
	(void)__wt_vpack_uint(&p, 0, rle);		/* RLE */
	return (WT_PTRDIFF(p, cell));
}

/*
 * __wt_cell_pack_int_key --
 *	Set a row-store internal page key's WT_CELL contents.
 */
static inline size_t
__wt_cell_pack_int_key(WT_CELL *cell, size_t size)
{
	uint8_t byte, *p;

	/* Short keys have 6 bits of data length in the descriptor byte. */
	if (size <= WT_CELL_SHORT_MAX) {
		byte = (uint8_t)size;
		cell->__chunk[0] = (uint8_t)
		    ((byte << WT_CELL_SHORT_SHIFT) | WT_CELL_KEY_SHORT);
		return (1);
	}

	cell->__chunk[0] = WT_CELL_KEY;			/* Type */
	p = cell->__chunk + 1;

	size -= WT_CELL_SIZE_ADJUST;
	(void)__wt_vpack_uint(&p, 0, (uint64_t)size);	/* Length */

	return (WT_PTRDIFF(p, cell));
}

/*
 * __wt_cell_pack_leaf_key --
 *	Set a row-store leaf page key's WT_CELL contents.
 */
static inline size_t
__wt_cell_pack_leaf_key(WT_CELL *cell, uint8_t prefix, size_t size)
{
	uint8_t byte, *p;

	/* Short keys have 6 bits of data length in the descriptor byte. */
	if (size <= WT_CELL_SHORT_MAX) {
		if (prefix == 0) {
			byte = (uint8_t)size;		/* Type + length */
			cell->__chunk[0] = (uint8_t)
			    ((byte << WT_CELL_SHORT_SHIFT) | WT_CELL_KEY_SHORT);
			return (1);
		}
		byte = (uint8_t)size;		/* Type + length */
		cell->__chunk[0] = (uint8_t)
		    ((byte << WT_CELL_SHORT_SHIFT) | WT_CELL_KEY_SHORT_PFX);
		cell->__chunk[1] = prefix;	/* Prefix */
		return (2);
	}

	if (prefix == 0) {
		cell->__chunk[0] = WT_CELL_KEY;		/* Type */
		p = cell->__chunk + 1;
	} else {
		cell->__chunk[0] = WT_CELL_KEY_PFX;	/* Type */
		cell->__chunk[1] = prefix;		/* Prefix */
		p = cell->__chunk + 2;
	}

	size -= WT_CELL_SIZE_ADJUST;
	(void)__wt_vpack_uint(&p, 0, (uint64_t)size);	/* Length */

	return (WT_PTRDIFF(p, cell));
}

/*
 * __wt_cell_pack_ovfl --
 *	Pack an overflow cell.
 */
static inline size_t
__wt_cell_pack_ovfl(WT_CELL *cell, uint8_t type, uint64_t rle, size_t size)
{
	uint8_t *p;

	p = cell->__chunk + 1;
	if (rle < 2)					/* Type */
		cell->__chunk[0] = type;
	else {
		cell->__chunk[0] = type | WT_CELL_64V;
		(void)__wt_vpack_uint(&p, 0, rle);	/* RLE */
	}
	(void)__wt_vpack_uint(&p, 0, (uint64_t)size);	/* Length */
	return (WT_PTRDIFF(p, cell));
}

/*
 * __wt_cell_rle --
 *	Return the cell's RLE value.
 */
static inline uint64_t
__wt_cell_rle(WT_CELL_UNPACK *unpack)
{
	/*
	 * Any item with only 1 occurrence is stored with an RLE of 0, that is,
	 * without any RLE at all.  This code is a single place to handle that
	 * correction, for simplicity.
	 */
	return (unpack->v < 2 ? 1 : unpack->v);
}

/*
 * __wt_cell_total_len --
 *	Return the cell's total length, including data.
 */
static inline size_t
__wt_cell_total_len(WT_CELL_UNPACK *unpack)
{
	/*
	 * The length field is specially named because it's dangerous to use it:
	 * it represents the length of the current cell (normally used for the
	 * loop that walks through cells on the page), but occasionally we want
	 * to copy a cell directly from the page, and what we need is the cell's
	 * total length. The problem is dictionary-copy cells, because in that
	 * case, the __len field is the length of the current cell, not the cell
	 * for which we're returning data.  To use the __len field, you must be
	 * sure you're not looking at a copy cell.
	 */
	return (unpack->__len);
}

/*
 * __wt_cell_type --
 *	Return the cell's type (collapsing special types).
 */
static inline u_int
__wt_cell_type(WT_CELL *cell)
{
	u_int type;

	switch (WT_CELL_SHORT_TYPE(cell->__chunk[0])) {
	case WT_CELL_KEY_SHORT:
	case WT_CELL_KEY_SHORT_PFX:
		return (WT_CELL_KEY);
	case WT_CELL_VALUE_SHORT:
		return (WT_CELL_VALUE);
	}

	switch (type = WT_CELL_TYPE(cell->__chunk[0])) {
	case WT_CELL_KEY_PFX:
		return (WT_CELL_KEY);
	case WT_CELL_KEY_OVFL_RM:
		return (WT_CELL_KEY_OVFL);
	case WT_CELL_VALUE_OVFL_RM:
		return (WT_CELL_VALUE_OVFL);
	}
	return (type);
}

/*
 * __wt_cell_type_raw --
 *	Return the cell's type.
 */
static inline u_int
__wt_cell_type_raw(WT_CELL *cell)
{
	return (WT_CELL_SHORT_TYPE(cell->__chunk[0]) == 0 ?
	    WT_CELL_TYPE(cell->__chunk[0]) :
	    WT_CELL_SHORT_TYPE(cell->__chunk[0]));
}

/*
 * __wt_cell_type_reset --
 *	Reset the cell's type.
 */
static inline void
__wt_cell_type_reset(
    WT_SESSION_IMPL *session, WT_CELL *cell, u_int old_type, u_int new_type)
{
	/*
	 * For all current callers of this function, this should happen once
	 * and only once, assert we're setting what we think we're setting.
	 */
	WT_ASSERT(session, old_type == 0 || old_type == __wt_cell_type(cell));
	WT_UNUSED(old_type);

	cell->__chunk[0] =
	    (cell->__chunk[0] & ~WT_CELL_TYPE_MASK) | WT_CELL_TYPE(new_type);
}

/*
 * __wt_cell_leaf_value_parse --
 *	Return the cell if it's a row-store leaf page value, otherwise return
 * NULL.
 */
static inline WT_CELL *
__wt_cell_leaf_value_parse(WT_PAGE *page, WT_CELL *cell)
{
	/*
	 * This function exists so there's a place for this comment.
	 *
	 * Row-store leaf pages may have a single data cell between each key, or
	 * keys may be adjacent (when the data cell is empty).
	 *
	 * One special case: if the last key on a page is a key without a value,
	 * don't walk off the end of the page: the size of the underlying disk
	 * image is exact, which means the end of the last cell on the page plus
	 * the length of the cell should be the byte immediately after the page
	 * disk image.
	 *
	 * !!!
	 * This line of code is really a call to __wt_off_page, but we know the
	 * cell we're given will either be on the page or past the end of page,
	 * so it's a simpler check.  (I wouldn't bother, but the real problem is
	 * we can't call __wt_off_page directly, it's in btree.i which requires
	 * this file be included first.)
	 */
	if (cell >= (WT_CELL *)((uint8_t *)page->dsk + page->dsk->mem_size))
		return (NULL);

	switch (__wt_cell_type_raw(cell)) {
	case WT_CELL_KEY:
	case WT_CELL_KEY_OVFL:
	case WT_CELL_KEY_OVFL_RM:
	case WT_CELL_KEY_PFX:
	case WT_CELL_KEY_SHORT:
	case WT_CELL_KEY_SHORT_PFX:
		return (NULL);
	default:
		return (cell);
	}
}

/*
 * __wt_cell_unpack_safe --
 *	Unpack a WT_CELL into a structure during verification.
 */
static inline int
__wt_cell_unpack_safe(
    WT_CELL *cell, WT_CELL_UNPACK *unpack, const void *start, const void *end)
{
	struct {
		uint32_t len;
		uint64_t v;
	} copy;
	uint64_t v;
	const uint8_t *p;

	copy.len = 0;
	copy.v = 0;			/* -Werror=maybe-uninitialized */

	/*
	 * The verification code specifies start/end arguments, pointers to the
	 * start of the page and to 1 past the end-of-page. In which case, make
	 * sure all reads are inside the page image. If an error occurs, return
	 * an error code but don't output messages, our caller handles that.
	 */
#define	WT_CELL_LEN_CHK(t, len) do {					\
	if (start != NULL &&						\
	    ((uint8_t *)(t) < (uint8_t *)start ||			\
	    (((uint8_t *)(t)) + (len)) > (uint8_t *)end))		\
		return (WT_ERROR);	        			\
} while (0)

restart:
	/*
	 * This path is performance critical for read-only trees, we're parsing
	 * on-page structures. For that reason we don't clear the unpacked cell
	 * structure (although that would be simpler), instead we make sure we
	 * initialize all structure elements either here or in the immediately
	 * following switch.
	 */
	WT_CELL_LEN_CHK(cell, 0);
	unpack->cell = cell;
	unpack->v = 0;
	unpack->raw = (uint8_t)__wt_cell_type_raw(cell);
	unpack->type = (uint8_t)__wt_cell_type(cell);
	unpack->ovfl = 0;

	/*
	 * Handle cells with neither an RLE count or data length: short key/data
	 * cells have 6 bits of data length in the descriptor byte.
	 */
	switch (unpack->raw) {
	case WT_CELL_KEY_SHORT_PFX:
		WT_CELL_LEN_CHK(cell, 1);		/* skip prefix */
		unpack->prefix = cell->__chunk[1];
		unpack->data = cell->__chunk + 2;
		unpack->size = cell->__chunk[0] >> WT_CELL_SHORT_SHIFT;
		unpack->__len = 2 + unpack->size;
		goto done;
	case WT_CELL_KEY_SHORT:
	case WT_CELL_VALUE_SHORT:
		unpack->prefix = 0;
		unpack->data = cell->__chunk + 1;
		unpack->size = cell->__chunk[0] >> WT_CELL_SHORT_SHIFT;
		unpack->__len = 1 + unpack->size;
		goto done;
	}

	unpack->prefix = 0;
	unpack->data = NULL;
	unpack->size = 0;
	unpack->__len = 0;

	p = (uint8_t *)cell + 1;			/* skip cell */

	/*
	 * Check for a prefix byte that optionally follows the cell descriptor
	 * byte on row-store leaf pages.
	 */
	if (unpack->raw == WT_CELL_KEY_PFX) {
		++p;					/* skip prefix */
		WT_CELL_LEN_CHK(p, 0);
		unpack->prefix = cell->__chunk[1];
	}

	/*
	 * Check for an RLE count or record number that optionally follows the
	 * cell descriptor byte on column-store variable-length pages.
	 */
	if (cell->__chunk[0] & WT_CELL_64V)		/* skip value */
		WT_RET(__wt_vunpack_uint(
		    &p, end == NULL ? 0 : WT_PTRDIFF(end, p), &unpack->v));

	/*
	 * Handle special actions for a few different cell types and set the
	 * data length (deleted cells are fixed-size without length bytes,
	 * almost everything else has data length bytes).
	 */
	switch (unpack->raw) {
	case WT_CELL_VALUE_COPY:
		/*
		 * The cell is followed by an offset to a cell written earlier
		 * in the page.  Save/restore the length and RLE of this cell,
		 * we need the length to step through the set of cells on the
		 * page and this RLE is probably different from the RLE of the
		 * earlier cell.
		 */
		WT_RET(__wt_vunpack_uint(
		    &p, end == NULL ? 0 : WT_PTRDIFF(end, p), &v));
		copy.len = WT_PTRDIFF32(p, cell);
		copy.v = unpack->v;
		cell = (WT_CELL *)((uint8_t *)cell - v);
		goto restart;

	case WT_CELL_KEY_OVFL:
	case WT_CELL_KEY_OVFL_RM:
	case WT_CELL_VALUE_OVFL:
	case WT_CELL_VALUE_OVFL_RM:
		/*
		 * Set overflow flag.
		 */
		unpack->ovfl = 1;
		/* FALLTHROUGH */

	case WT_CELL_ADDR_DEL:
	case WT_CELL_ADDR_INT:
	case WT_CELL_ADDR_LEAF:
	case WT_CELL_ADDR_LEAF_NO:
	case WT_CELL_KEY:
	case WT_CELL_KEY_PFX:
	case WT_CELL_VALUE:
		/*
		 * The cell is followed by a 4B data length and a chunk of
		 * data.
		 */
		WT_RET(__wt_vunpack_uint(
		    &p, end == NULL ? 0 : WT_PTRDIFF(end, p), &v));

		if (unpack->raw == WT_CELL_KEY ||
		    unpack->raw == WT_CELL_KEY_PFX ||
		    (unpack->raw == WT_CELL_VALUE && unpack->v == 0))
			v += WT_CELL_SIZE_ADJUST;

		unpack->data = p;
		unpack->size = (uint32_t)v;
		unpack->__len = WT_PTRDIFF32(p + unpack->size, cell);
		break;

	case WT_CELL_DEL:
		unpack->__len = WT_PTRDIFF32(p, cell);
		break;
	default:
		return (WT_ERROR);		/* Unknown cell type. */
	}

	/*
	 * Check the original cell against the full cell length (this is a
	 * diagnostic as well, we may be copying the cell from the page and
	 * we need the right length).
	 */
done:	WT_CELL_LEN_CHK(cell, unpack->__len);
	if (copy.len != 0) {
		unpack->raw = WT_CELL_VALUE_COPY;
		unpack->__len = copy.len;
		unpack->v = copy.v;
	}

	return (0);
}

/*
 * __wt_cell_unpack --
 *	Unpack a WT_CELL into a structure.
 */
static inline void
__wt_cell_unpack(WT_CELL *cell, WT_CELL_UNPACK *unpack)
{
	/*
	 * Row-store doesn't store zero-length values on pages, but this allows
	 * us to pretend.
	 */
	if (cell == NULL) {
		unpack->cell = NULL;
		unpack->v = 0;
		unpack->data = "";
		unpack->size = 0;
		unpack->__len = 0;
		unpack->prefix = 0;
		unpack->raw = unpack->type = WT_CELL_VALUE;
		unpack->ovfl = 0;
		return;
	}

	(void)__wt_cell_unpack_safe(cell, unpack, NULL, NULL);
}

/*
 * __cell_data_ref --
 *	Set a buffer to reference the data from an unpacked cell.
 */
static inline int
__cell_data_ref(WT_SESSION_IMPL *session,
    WT_PAGE *page, int page_type, WT_CELL_UNPACK *unpack, WT_ITEM *store)
{
	WT_BTREE *btree;
	bool decoded;
	void *huffman;

	btree = S2BT(session);

	/* Reference the cell's data, optionally decode it. */
	switch (unpack->type) {
	case WT_CELL_KEY:
		store->data = unpack->data;
		store->size = unpack->size;
		if (page_type == WT_PAGE_ROW_INT)
			return (0);

		huffman = btree->huffman_key;
		break;
	case WT_CELL_VALUE:
		store->data = unpack->data;
		store->size = unpack->size;
		huffman = btree->huffman_value;
		break;
	case WT_CELL_KEY_OVFL:
		WT_RET(__wt_ovfl_read(session, page, unpack, store, &decoded));
		if (page_type == WT_PAGE_ROW_INT || decoded)
			return (0);

		huffman = btree->huffman_key;
		break;
	case WT_CELL_VALUE_OVFL:
		WT_RET(__wt_ovfl_read(session, page, unpack, store, &decoded));
		if (decoded)
			return (0);
		huffman = btree->huffman_value;
		break;
	WT_ILLEGAL_VALUE(session, unpack->type);
	}

	return (huffman == NULL || store->size == 0 ? 0 :
	    __wt_huffman_decode(
	    session, huffman, store->data, store->size, store));
}

/*
 * __wt_dsk_cell_data_ref --
 *	Set a buffer to reference the data from an unpacked cell.
 *
 * There are two versions because of WT_CELL_VALUE_OVFL_RM type cells.  When an
 * overflow item is deleted, its backing blocks are removed; if there are still
 * running transactions that might need to see the overflow item, we cache a
 * copy of the item and reset the item's cell to WT_CELL_VALUE_OVFL_RM.  If we
 * find a WT_CELL_VALUE_OVFL_RM cell when reading an overflow item, we use the
 * page reference to look aside into the cache.  So, calling the "dsk" version
 * of the function declares the cell cannot be of type WT_CELL_VALUE_OVFL_RM,
 * and calling the "page" version means it might be.
 */
static inline int
__wt_dsk_cell_data_ref(WT_SESSION_IMPL *session,
    int page_type, WT_CELL_UNPACK *unpack, WT_ITEM *store)
{
	WT_ASSERT(session,
	    __wt_cell_type_raw(unpack->cell) != WT_CELL_VALUE_OVFL_RM);
	return (__cell_data_ref(session, NULL, page_type, unpack, store));
}

/*
 * __wt_page_cell_data_ref --
 *	Set a buffer to reference the data from an unpacked cell.
 */
static inline int
__wt_page_cell_data_ref(WT_SESSION_IMPL *session,
    WT_PAGE *page, WT_CELL_UNPACK *unpack, WT_ITEM *store)
{
	return (__cell_data_ref(session, page, page->type, unpack, store));
}
