
/**
 *    Copyright (C) 2018-present MongoDB, Inc.
 *
 *    This program is free software: you can redistribute it and/or modify
 *    it under the terms of the Server Side Public License, version 1,
 *    as published by MongoDB, Inc.
 *
 *    This program is distributed in the hope that it will be useful,
 *    but WITHOUT ANY WARRANTY; without even the implied warranty of
 *    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *    Server Side Public License for more details.
 *
 *    You should have received a copy of the Server Side Public License
 *    along with this program. If not, see
 *    <http://www.mongodb.com/licensing/server-side-public-license>.
 *
 *    As a special exception, the copyright holders give permission to link the
 *    code of portions of this program with the OpenSSL library under certain
 *    conditions as described in each individual source file and distribute
 *    linked combinations including the program with the OpenSSL library. You
 *    must comply with the Server Side Public License in all respects for
 *    all of the code used other than as permitted herein. If you modify file(s)
 *    with this exception, you may extend this exception to your version of the
 *    file(s), but you are not obligated to do so. If you do not wish to do so,
 *    delete this exception statement from your version. If you delete this
 *    exception statement from all source files in the program, then also delete
 *    it in the license file.
 */

#pragma once

#include "mongo/db/logical_session_id.h"

namespace mongo {

/**
 * Parses the session information from the body of a request and stores the sessionId and txnNumber
 * on the current operation context. Must only be called once per operation and should be done right
 * in the beginning.
 *
 * Throws if the sessionId/txnNumber combination is not properly formatted.
 *
 * requiresAuth specifies if the command we're initializing operationSessionInfo for requires
 * authorization or not.  This can be determined by invoking ->requiresAuth() on the parsed command.
 * If it does not require authorization, return boost::none.
 *
 * Both isReplSetMemberOrMongos and supportsDocLocking need to be true if the command contains a
 * transaction number, otherwise this function will throw.
 *
 * On success, returns the parsed request information. Returning boost::none implies that the
 * proper command or session requirements were not met.
 */
OperationSessionInfoFromClient initializeOperationSessionInfo(OperationContext* opCtx,
                                                              const BSONObj& requestBody,
                                                              bool requiresAuth,
                                                              bool isReplSetMemberOrMongos,
                                                              bool supportsDocLocking);

}  // namespace mongo
