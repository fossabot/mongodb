
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
#define MONGO_LOG_DEFAULT_COMPONENT ::mongo::logger::LogComponent::kFTDC

#include "mongo/platform/basic.h"

#include "mongo/db/ftdc/ftdc_mongos.h"

#include <boost/filesystem.hpp>

#include "mongo/client/connpool.h"
#include "mongo/client/dbclientinterface.h"
#include "mongo/client/global_conn_pool.h"
#include "mongo/db/ftdc/controller.h"
#include "mongo/db/ftdc/ftdc_server.h"
#include "mongo/db/repl/replication_coordinator.h"
#include "mongo/db/server_parameters.h"
#include "mongo/executor/connection_pool_stats.h"
#include "mongo/executor/task_executor_pool.h"
#include "mongo/s/grid.h"
#include "mongo/stdx/thread.h"
#include "mongo/util/log.h"

namespace mongo {

namespace {

/**
 * Expose diagnosticDataCollectionDirectoryPath set parameter to specify the MongoS FTDC path.
 */
class ExportedFTDCDirectoryPathParameter : public ServerParameter {
public:
    ExportedFTDCDirectoryPathParameter()
        : ServerParameter(ServerParameterSet::getGlobal(),
                          "diagnosticDataCollectionDirectoryPath",
                          true,
                          true) {}


    void append(OperationContext* opCtx, BSONObjBuilder& b, const std::string& name) final {
        stdx::lock_guard<stdx::mutex> guard(_lock);
        b.append(name, _path.generic_string());
    }

    Status set(const BSONElement& newValueElement) {
        if (newValueElement.type() != String) {
            return Status(ErrorCodes::BadValue,
                          "diagnosticDataCollectionDirectoryPath only supports type string");
        }

        std::string str = newValueElement.str();
        return setFromString(str);
    }

    Status setFromString(const std::string& str) final {
        stdx::lock_guard<stdx::mutex> guard(_lock);

        FTDCController* controller = nullptr;

        if (hasGlobalServiceContext()) {
            controller = FTDCController::get(getGlobalServiceContext());
        }

        if (controller) {
            Status s = controller->setDirectory(str);
            if (!s.isOK()) {
                return s;
            }
        }

        _path = str;

        return Status::OK();
    }

    boost::filesystem::path getDirectory() {
        stdx::lock_guard<stdx::mutex> guard(_lock);
        return _path;
    }

    void setDirectory(boost::filesystem::path& path) {
        stdx::lock_guard<stdx::mutex> guard(_lock);
        _path = path;
    }

private:
    // Lock to guard _path
    stdx::mutex _lock;

    // Directory location of ftdc files, guarded by _lock
    boost::filesystem::path _path;
} exportedFTDCDirectoryPathParameter;

class ConnPoolStatsCollector : public FTDCCollectorInterface {
public:
    void collect(OperationContext* opCtx, BSONObjBuilder& builder) override {
        executor::ConnectionPoolStats stats{};

        // Global connection pool connections.
        globalConnPool.appendConnectionStats(&stats);

        // Sharding connections.
        {
            auto const grid = Grid::get(opCtx);
            if (grid->getExecutorPool()) {
                grid->getExecutorPool()->appendConnectionStats(&stats);
            }

            auto const customConnPoolStatsFn = grid->getCustomConnectionPoolStatsFn();
            if (customConnPoolStatsFn) {
                customConnPoolStatsFn(&stats);
            }
        }

        // Output to a BSON object.
        builder.appendNumber("numClientConnections", DBClientConnection::getNumConnections());
        builder.appendNumber("numAScopedConnections", AScopedConnection::getNumConnections());
        stats.appendToBSON(builder, true /* forFTDC */);

        // All replica sets being tracked.
        globalRSMonitorManager.report(&builder, true /* forFTDC */);
    }

    std::string name() const override {
        return "connPoolStats";
    }
};

void registerMongoSCollectors(FTDCController* controller) {
    // PoolStats
    controller->addPeriodicCollector(stdx::make_unique<ConnPoolStatsCollector>());
}

}  // namespace

void startMongoSFTDC() {
    // Get the path to use for FTDC:
    // 1. Check if the user set one.
    // 2. If not, check if the user has a logpath and derive one.
    // 3. Otherwise, tell the user FTDC cannot run.

    // Only attempt to enable FTDC if we have a path to log files to.
    FTDCStartMode startMode = FTDCStartMode::kStart;
    auto directory = exportedFTDCDirectoryPathParameter.getDirectory();

    if (directory.empty()) {
        if (serverGlobalParams.logpath.empty()) {
            warning() << "FTDC is disabled because neither '--logpath' nor set parameter "
                         "'diagnosticDataCollectionDirectoryPath' are specified.";
            startMode = FTDCStartMode::kSkipStart;
        } else {
            directory = boost::filesystem::absolute(
                FTDCUtil::getMongoSPath(serverGlobalParams.logpath), serverGlobalParams.cwd);

            // Update the server parameter with the computed path.
            // Note: If the computed FTDC directory conflicts with an existing file, then FTDC will
            // warn about the conflict, and not startup. It will not terminate MongoS in this
            // situation.
            exportedFTDCDirectoryPathParameter.setDirectory(directory);
        }
    }

    startFTDC(directory, startMode, registerMongoSCollectors);
}

void stopMongoSFTDC() {
    stopFTDC();
}

}  // namespace mongo
