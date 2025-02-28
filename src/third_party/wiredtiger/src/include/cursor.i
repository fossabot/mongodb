/*-
 * Copyright (c) 2014-2019 MongoDB, Inc.
 * Copyright (c) 2008-2014 WiredTiger, Inc.
 *	All rights reserved.
 *
 * See the file LICENSE for redistribution information.
 */

/*
 * __cursor_set_recno --
 *	The cursor value in the interface has to track the value in the
 * underlying cursor, update them in parallel.
 */
static inline void
__cursor_set_recno(WT_CURSOR_BTREE *cbt, uint64_t v)
{
	cbt->iface.recno = cbt->recno = v;
}

/*
 * __cursor_novalue --
 *	Release any cached value before an operation that could update the
 * transaction context and free data a value is pointing to.
 */
static inline void
__cursor_novalue(WT_CURSOR *cursor)
{
	F_CLR(cursor, WT_CURSTD_VALUE_INT);
}

/*
 * __cursor_checkkey --
 *	Check if a key is set without making a copy.
 */
static inline int
__cursor_checkkey(WT_CURSOR *cursor)
{
	return (F_ISSET(cursor, WT_CURSTD_KEY_SET) ?
	    0 : __wt_cursor_kv_not_set(cursor, true));
}

/*
 * __cursor_checkvalue --
 *	Check if a value is set without making a copy.
 */
static inline int
__cursor_checkvalue(WT_CURSOR *cursor)
{
	return (F_ISSET(cursor, WT_CURSTD_VALUE_SET) ?
	    0 : __wt_cursor_kv_not_set(cursor, false));
}

/*
 * __cursor_localkey --
 *	If the key points into the tree, get a local copy.
 */
static inline int
__cursor_localkey(WT_CURSOR *cursor)
{
	if (F_ISSET(cursor, WT_CURSTD_KEY_INT)) {
		if (!WT_DATA_IN_ITEM(&cursor->key))
			WT_RET(__wt_buf_set((WT_SESSION_IMPL *)cursor->session,
			    &cursor->key, cursor->key.data, cursor->key.size));
		F_CLR(cursor, WT_CURSTD_KEY_INT);
		F_SET(cursor, WT_CURSTD_KEY_EXT);
	}
	return (0);
}

/*
 * __cursor_localvalue --
 *	If the value points into the tree, get a local copy.
 */
static inline int
__cursor_localvalue(WT_CURSOR *cursor)
{
	if (F_ISSET(cursor, WT_CURSTD_VALUE_INT)) {
		if (!WT_DATA_IN_ITEM(&cursor->value))
			WT_RET(__wt_buf_set((WT_SESSION_IMPL *)cursor->session,
			    &cursor->value,
			    cursor->value.data, cursor->value.size));
		F_CLR(cursor, WT_CURSTD_VALUE_INT);
		F_SET(cursor, WT_CURSTD_VALUE_EXT);
	}
	return (0);
}

/*
 * __cursor_needkey --
 *
 * Check if we have a key set. There's an additional semantic here: if we're
 * pointing into the tree, get a local copy of whatever we're referencing in
 * the tree, there's an obvious race with the cursor moving and the reference.
 */
static inline int
__cursor_needkey(WT_CURSOR *cursor)
{
	WT_RET(__cursor_localkey(cursor));
	return (__cursor_checkkey(cursor));
}

/*
 * __cursor_needvalue --
 *
 * Check if we have a value set. There's an additional semantic here: if we're
 * pointing into the tree, get a local copy of whatever we're referencing in
 * the tree, there's an obvious race with the cursor moving and the reference.
 */
static inline int
__cursor_needvalue(WT_CURSOR *cursor)
{
	WT_RET(__cursor_localvalue(cursor));
	return (__cursor_checkvalue(cursor));
}

/*
 * __cursor_pos_clear --
 *	Reset the cursor's location.
 */
static inline void
__cursor_pos_clear(WT_CURSOR_BTREE *cbt)
{
	/*
	 * Most of the cursor's location information that needs to be set on
	 * successful return is always set by a successful return, for example,
	 * we don't initialize the compare return value because it's always
	 * set by the row-store search.  The other stuff gets cleared here,
	 * and it's a minimal set of things we need to clear. It would be a
	 * lot simpler to clear everything, but we call this function a lot.
	 */
	cbt->recno = WT_RECNO_OOB;

	cbt->ins = NULL;
	cbt->ins_head = NULL;
	cbt->ins_stack[0] = NULL;

	F_CLR(cbt, WT_CBT_POSITION_MASK);
}

/*
 * __cursor_enter --
 *	Activate a cursor.
 */
static inline int
__cursor_enter(WT_SESSION_IMPL *session)
{
	/*
	 * If there are no other cursors positioned in the session, check
	 * whether the cache is full.
	 */
	if (session->ncursors == 0)
		WT_RET(__wt_cache_eviction_check(session, false, false, NULL));
	++session->ncursors;
	return (0);
}

/*
 * __cursor_leave --
 *	Deactivate a cursor.
 */
static inline void
__cursor_leave(WT_SESSION_IMPL *session)
{
	/*
	 * Decrement the count of active cursors in the session.  When that
	 * goes to zero, there are no active cursors, and we can release any
	 * snapshot we're holding for read committed isolation.
	 */
	WT_ASSERT(session, session->ncursors > 0);
	if (--session->ncursors == 0)
		__wt_txn_read_last(session);
}

/*
 * __cursor_reset --
 *	Reset the cursor, it no longer holds any position.
 */
static inline int
__cursor_reset(WT_CURSOR_BTREE *cbt)
{
	WT_DECL_RET;
	WT_SESSION_IMPL *session;

	session = (WT_SESSION_IMPL *)cbt->iface.session;

	__cursor_pos_clear(cbt);

	/* If the cursor was active, deactivate it. */
	if (F_ISSET(cbt, WT_CBT_ACTIVE)) {
		if (!F_ISSET(cbt, WT_CBT_NO_TXN))
			__cursor_leave(session);
		F_CLR(cbt, WT_CBT_ACTIVE);
	}

	/* If we're not holding a cursor reference, we're done. */
	if (cbt->ref == NULL)
		return (0);

	/*
	 * If we were scanning and saw a lot of deleted records on this page,
	 * try to evict the page when we release it.
	 */
	if (cbt->page_deleted_count > WT_BTREE_DELETE_THRESHOLD)
		__wt_page_evict_soon(session, cbt->ref);
	cbt->page_deleted_count = 0;

	/*
	 * Release any page references we're holding. This can trigger eviction
	 * (e.g., forced eviction of big pages), so it's important to do after
	 * releasing our snapshot above.
	 *
	 * Clear the reference regardless, so we don't try the release twice.
	 */
	ret = __wt_page_release(session, cbt->ref, 0);
	cbt->ref = NULL;

	return (ret);
}

/*
 * __wt_curindex_get_valuev --
 *	Internal implementation of WT_CURSOR->get_value for index cursors
 */
static inline int
__wt_curindex_get_valuev(WT_CURSOR *cursor, va_list ap)
{
	WT_CURSOR_INDEX *cindex;
	WT_ITEM *item;
	WT_SESSION_IMPL *session;

	cindex = (WT_CURSOR_INDEX *)cursor;
	session = (WT_SESSION_IMPL *)cursor->session;
	WT_RET(__cursor_checkvalue(cursor));

	if (F_ISSET(cursor, WT_CURSOR_RAW_OK)) {
		WT_RET(__wt_schema_project_merge(session,
		    cindex->cg_cursors, cindex->value_plan,
		    cursor->value_format, &cursor->value));
		item = va_arg(ap, WT_ITEM *);
		item->data = cursor->value.data;
		item->size = cursor->value.size;
	} else
		WT_RET(__wt_schema_project_out(session,
		    cindex->cg_cursors, cindex->value_plan, ap));
	return (0);
}

/*
 * __wt_curtable_get_valuev --
 *	Internal implementation of WT_CURSOR->get_value for table cursors.
 */
static inline int
__wt_curtable_get_valuev(WT_CURSOR *cursor, va_list ap)
{
	WT_CURSOR *primary;
	WT_CURSOR_TABLE *ctable;
	WT_ITEM *item;
	WT_SESSION_IMPL *session;

	ctable = (WT_CURSOR_TABLE *)cursor;
	session = (WT_SESSION_IMPL *)cursor->session;
	primary = *ctable->cg_cursors;
	WT_RET(__cursor_checkvalue(primary));

	if (F_ISSET(cursor, WT_CURSOR_RAW_OK)) {
		WT_RET(__wt_schema_project_merge(session,
		    ctable->cg_cursors, ctable->plan,
		    cursor->value_format, &cursor->value));
		item = va_arg(ap, WT_ITEM *);
		item->data = cursor->value.data;
		item->size = cursor->value.size;
	} else
		WT_RET(__wt_schema_project_out(session,
		    ctable->cg_cursors, ctable->plan, ap));
	return (0);
}

/*
 * __wt_cursor_dhandle_incr_use --
 *	Increment the in-use counter in the cursor's data source.
 */
static inline void
__wt_cursor_dhandle_incr_use(WT_SESSION_IMPL *session)
{
	WT_DATA_HANDLE *dhandle;

	dhandle = session->dhandle;

	/* If we open a handle with a time of death set, clear it. */
	if (__wt_atomic_addi32(&dhandle->session_inuse, 1) == 1 &&
	    dhandle->timeofdeath != 0)
		dhandle->timeofdeath = 0;
}

/*
 * __wt_cursor_dhandle_decr_use --
 *	Decrement the in-use counter in the cursor's data source.
 */
static inline void
__wt_cursor_dhandle_decr_use(WT_SESSION_IMPL *session)
{
	WT_DATA_HANDLE *dhandle;

	dhandle = session->dhandle;

	/* If we close a handle with a time of death set, clear it. */
	WT_ASSERT(session, dhandle->session_inuse > 0);
	if (__wt_atomic_subi32(&dhandle->session_inuse, 1) == 0 &&
	    dhandle->timeofdeath != 0)
		dhandle->timeofdeath = 0;
}

/*
 * __cursor_kv_return --
 *      Return a page referenced key/value pair to the application.
 */
static inline int
__cursor_kv_return(
    WT_SESSION_IMPL *session, WT_CURSOR_BTREE *cbt, WT_UPDATE *upd)
{
	WT_RET(__wt_key_return(session, cbt));
	WT_RET(__wt_value_return(session, cbt, upd));

	return (0);
}

/*
 * __cursor_func_init --
 *	Cursor call setup.
 */
static inline int
__cursor_func_init(WT_CURSOR_BTREE *cbt, bool reenter)
{
	WT_SESSION_IMPL *session;

	session = (WT_SESSION_IMPL *)cbt->iface.session;

	if (reenter) {
#ifdef HAVE_DIAGNOSTIC
		__wt_cursor_key_order_reset(cbt);
#endif
		WT_RET(__cursor_reset(cbt));
	}

	/*
	 * Any old insert position is now invalid.  We rely on this being
	 * cleared to detect if a new skiplist is installed after a search.
	 */
	cbt->ins_stack[0] = NULL;

	/* If the transaction is idle, check that the cache isn't full. */
	WT_RET(__wt_txn_idle_cache_check(session));

	/* Activate the file cursor. */
	if (!F_ISSET(cbt, WT_CBT_ACTIVE)) {
		if (!F_ISSET(cbt, WT_CBT_NO_TXN))
			WT_RET(__cursor_enter(session));
		F_SET(cbt, WT_CBT_ACTIVE);
	}

	/*
	 * If this is an ordinary transactional cursor, make sure we are set up
	 * to read.
	 */
	if (!F_ISSET(cbt, WT_CBT_NO_TXN))
		__wt_txn_cursor_op(session);
	return (0);
}

/*
 * __cursor_row_slot_return --
 *	Return a row-store leaf page slot's K/V pair.
 */
static inline int
__cursor_row_slot_return(WT_CURSOR_BTREE *cbt, WT_ROW *rip, WT_UPDATE *upd)
{
	WT_BTREE *btree;
	WT_CELL *cell;
	WT_CELL_UNPACK *kpack, _kpack, *vpack, _vpack;
	WT_ITEM *kb, *vb;
	WT_PAGE *page;
	WT_SESSION_IMPL *session;
	void *copy;

	session = (WT_SESSION_IMPL *)cbt->iface.session;
	btree = S2BT(session);
	page = cbt->ref->page;

	kpack = NULL;
	vpack = &_vpack;

	kb = &cbt->iface.key;
	vb = &cbt->iface.value;

	/*
	 * The row-store key can change underfoot; explicitly take a copy.
	 */
	copy = WT_ROW_KEY_COPY(rip);

	/*
	 * Get a key: we could just call __wt_row_leaf_key, but as a cursor
	 * is running through the tree, we may have additional information
	 * here (we may have the fully-built key that's immediately before
	 * the prefix-compressed key we want, so it's a faster construction).
	 *
	 * First, check for an immediately available key.
	 */
	if (__wt_row_leaf_key_info(
	    page, copy, NULL, &cell, &kb->data, &kb->size))
		goto value;

	/* Huffman encoded keys are a slow path in all cases. */
	if (btree->huffman_key != NULL)
		goto slow;

	/*
	 * Unpack the cell and deal with overflow and prefix-compressed keys.
	 * Inline building simple prefix-compressed keys from a previous key,
	 * otherwise build from scratch.
	 *
	 * Clear the key cell structure. It shouldn't be necessary (as far as I
	 * can tell, and we don't do it in lots of other places), but disabling
	 * shared builds (--disable-shared) results in the compiler complaining
	 * about uninitialized field use.
	 */
	kpack = &_kpack;
	memset(kpack, 0, sizeof(*kpack));
	__wt_cell_unpack(cell, kpack);
	if (kpack->type == WT_CELL_KEY &&
	    cbt->rip_saved != NULL && cbt->rip_saved == rip - 1) {
		WT_ASSERT(session, cbt->row_key->size >= kpack->prefix);

		/*
		 * Grow the buffer as necessary as well as ensure data has been
		 * copied into local buffer space, then append the suffix to the
		 * prefix already in the buffer.
		 *
		 * Don't grow the buffer unnecessarily or copy data we don't
		 * need, truncate the item's data length to the prefix bytes.
		 */
		cbt->row_key->size = kpack->prefix;
		WT_RET(__wt_buf_grow(
		    session, cbt->row_key, cbt->row_key->size + kpack->size));
		memcpy((uint8_t *)cbt->row_key->data + cbt->row_key->size,
		    kpack->data, kpack->size);
		cbt->row_key->size += kpack->size;
	} else {
		/*
		 * Call __wt_row_leaf_key_work instead of __wt_row_leaf_key: we
		 * already did __wt_row_leaf_key's fast-path checks inline.
		 */
slow:		WT_RET(__wt_row_leaf_key_work(
		    session, page, rip, cbt->row_key, false));
	}
	kb->data = cbt->row_key->data;
	kb->size = cbt->row_key->size;
	cbt->rip_saved = rip;

value:
	/*
	 * If the item was ever modified, use the WT_UPDATE data.  Note the
	 * caller passes us the update: it has already resolved which one
	 * (if any) is visible.
	 */
	if (upd != NULL)
		return (__wt_value_return(session, cbt, upd));

	/* Else, simple values have their location encoded in the WT_ROW. */
	if (__wt_row_leaf_value(page, rip, vb))
		return (0);

	/* Else, take the value from the original page cell. */
	__wt_row_leaf_value_cell(page, rip, kpack, vpack);
	return (__wt_page_cell_data_ref(session, cbt->ref->page, vpack, vb));
}
/*
 * __cursor_check_prepared_update --
 *	Return whether prepared update at current position is visible or not.
 */
static inline int
__cursor_check_prepared_update(WT_CURSOR_BTREE *cbt, bool *visiblep)
{
	WT_SESSION_IMPL *session;
	WT_UPDATE *upd;

	session = (WT_SESSION_IMPL *)cbt->iface.session;
	/*
	 * When retrying an operation due to a prepared conflict, the cursor is
	 * at an update list which resulted in conflict. So, when retrying we
	 * should examine the same update again instead of iterating to the next
	 * object. We'll eventually find a valid update, else return
	 * prepare-conflict until resolved.
	 */
	WT_RET(__wt_cursor_valid(cbt, &upd, visiblep));

	/* The update that returned prepared conflict is now visible. */
	F_CLR(cbt, WT_CBT_ITERATE_RETRY_NEXT | WT_CBT_ITERATE_RETRY_PREV);
	if (*visiblep)
		WT_RET(__cursor_kv_return(session, cbt, upd));

	return (0);
}
