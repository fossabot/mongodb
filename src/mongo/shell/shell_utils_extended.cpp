// mongo/shell/shell_utils_extended.cpp

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

#define MONGO_LOG_DEFAULT_COMPONENT ::mongo::logger::LogComponent::kDefault

#include "mongo/platform/basic.h"

#ifndef _WIN32
#include <sys/stat.h>
#include <sys/types.h>
#endif

#include <boost/filesystem.hpp>
#include <fstream>

#include "mongo/scripting/engine.h"
#include "mongo/shell/shell_utils.h"
#include "mongo/shell/shell_utils_launcher.h"
#include "mongo/util/file.h"
#include "mongo/util/log.h"
#include "mongo/util/md5.hpp"
#include "mongo/util/mongoutils/str.h"
#include "mongo/util/net/socket_utils.h"
#include "mongo/util/scopeguard.h"
#include "mongo/util/text.h"

namespace mongo {

using std::ifstream;
using std::string;
using std::stringstream;

/**
 * These utilities are thread safe but do not provide mutually exclusive access to resources
 * identified by the caller.  Dependent filesystem paths should not be accessed by different
 * threads.
 */
namespace shell_utils {

BSONObj listFiles(const BSONObj& _args, void* data) {
    BSONObj cd = BSON("0"
                      << ".");
    BSONObj args = _args.isEmpty() ? cd : _args;

    uassert(10257, "need to specify 1 argument to listFiles", args.nFields() == 1);

    BSONArrayBuilder lst;

    string rootname = args.firstElement().valuestrsafe();
    boost::filesystem::path root(rootname);
    stringstream ss;
    ss << "listFiles: no such directory: " << rootname;
    string msg = ss.str();
    uassert(12581, msg.c_str(), boost::filesystem::exists(root));

    boost::filesystem::directory_iterator end;
    boost::filesystem::directory_iterator i(root);

    while (i != end) {
        boost::filesystem::path p = *i;
        BSONObjBuilder b;
        b << "name" << p.generic_string();
        b << "baseName" << p.filename().generic_string();
        b.appendBool("isDirectory", is_directory(p));
        if (!boost::filesystem::is_directory(p)) {
            try {
                b.append("size", (double)boost::filesystem::file_size(p));
            } catch (...) {
                i++;
                continue;
            }
        }

        lst.append(b.obj());
        i++;
    }

    BSONObjBuilder ret;
    ret.appendArray("", lst.done());
    return ret.obj();
}

BSONObj ls(const BSONObj& args, void* data) {
    BSONArrayBuilder ret;
    BSONObj o = listFiles(args, data);
    if (!o.isEmpty()) {
        for (auto&& elem : o.firstElement().Obj()) {
            BSONObj f = elem.Obj();
            string name = f["name"].String();
            if (f["isDirectory"].trueValue()) {
                name += '/';
            }
            ret << name;
        }
    }
    return BSON("" << ret.arr());
}

/** Set process wide current working directory. */
BSONObj cd(const BSONObj& args, void* data) {
    uassert(16830, "cd requires one argument -- cd(directory)", args.nFields() == 1);
    uassert(16831,
            "cd requires a string argument -- cd(directory)",
            args.firstElement().type() == String);
#if defined(_WIN32)
    std::wstring dir = toWideString(args.firstElement().String().c_str());
    if (SetCurrentDirectoryW(dir.c_str())) {
        return BSONObj();
    }
#else
    std::string dir = args.firstElement().String();
    if (chdir(dir.c_str()) == 0) {
        return BSONObj();
    }
#endif
    uasserted(16832, mongoutils::str::stream() << "cd command failed: " << errnoWithDescription());
    return BSONObj();
}

BSONObj pwd(const BSONObj&, void* data) {
    boost::filesystem::path p = boost::filesystem::current_path();
    return BSON("" << p.string());
}

BSONObj hostname(const BSONObj&, void* data) {
    return BSON("" << getHostName());
}

const int CANT_OPEN_FILE = 13300;

BSONObj cat(const BSONObj& args, void* data) {
    BSONObjIterator it(args);

    auto filePath = it.next();
    uassert(51012,
            "the first argument to cat() must be a string containing the path to the file",
            filePath.type() == mongo::String);

    std::ios::openmode mode = std::ios::in;

    auto useBinary = it.next();
    if (!useBinary.eoo()) {
        uassert(51013,
                "the second argument to cat(), must be a boolean indicating whether "
                "or not to read the file in binary mode. If omitted, the default is 'false'.",
                useBinary.type() == mongo::Bool);

        if (useBinary.Bool())
            mode |= std::ios::binary;
    }

    stringstream ss;
    ifstream f(filePath.valuestrsafe(), mode);
    uassert(CANT_OPEN_FILE, "couldn't open file", f.is_open());

    std::streamsize sz = 0;
    while (1) {
        char ch = 0;
        f.get(ch);
        if (ch == 0)
            break;
        ss << ch;
        sz += 1;
        uassert(13301, "cat() : file to big to load as a variable", sz < 1024 * 1024 * 16);
    }
    return BSON("" << ss.str());
}

BSONObj md5sumFile(const BSONObj& args, void* data) {
    BSONElement e = singleArg(args);
    stringstream ss;
    FILE* f = fopen(e.valuestrsafe(), "rb");
    uassert(CANT_OPEN_FILE, "couldn't open file", f);
    ON_BLOCK_EXIT(fclose, f);

    md5digest d;
    md5_state_t st;
    md5_init(&st);

    enum { BUFLEN = 4 * 1024 };
    char buffer[BUFLEN];
    int bytes_read;
    while ((bytes_read = fread(buffer, 1, BUFLEN, f))) {
        md5_append(&st, (const md5_byte_t*)(buffer), bytes_read);
    }

    md5_finish(&st, d);
    return BSON("" << digestToString(d));
}

BSONObj mkdir(const BSONObj& args, void* data) {
    uassert(16833, "mkdir requires one argument -- mkdir(directory)", args.nFields() == 1);
    uassert(16834,
            "mkdir requires a string argument -- mkdir(directory)",
            args.firstElement().type() == String);

    // Boost bug 12495 (https://svn.boost.org/trac/boost/ticket/12495):
    // create_directories crashes on empty string. We expect mkdir("") to
    // fail on the OS level anyway, so catch it here instead.
    uassert(40315, "mkdir requires a non-empty string", args.firstElement().String() != "");

    boost::system::error_code ec;
    auto created = boost::filesystem::create_directories(args.firstElement().String(), ec);

    uassert(40316, "mkdir() failed: " + ec.message(), !ec);

    BSONObjBuilder wrapper;
    BSONObjBuilder res(wrapper.subobjStart(""));
    res.append("exists", true);
    res.append("created", created);
    res.done();
    return wrapper.obj();
}

BSONObj removeFile(const BSONObj& args, void* data) {
    BSONElement e = singleArg(args);
    bool found = false;

    boost::filesystem::path root(e.valuestrsafe());
    if (boost::filesystem::exists(root)) {
        found = true;
        boost::filesystem::remove_all(root);
    }

    BSONObjBuilder b;
    b.appendBool("removed", found);
    return b.obj();
}

/**
 * @param args - [ source, destination ]
 * copies file 'source' to 'destination'. Errors if the 'destination' file already exists.
 */
BSONObj copyFile(const BSONObj& args, void* data) {
    uassert(13619, "copyFile takes 2 arguments", args.nFields() == 2);

    BSONObjIterator it(args);
    const std::string source = it.next().str();
    const std::string destination = it.next().str();

    boost::filesystem::copy_file(source, destination);

    return undefinedReturn;
}

BSONObj writeFile(const BSONObj& args, void* data) {
    // Parse the arguments.

    uassert(
        40340,
        "writeFile requires at least 2 arguments: writeFile(filePath, content, [useBinaryMode])",
        args.nFields() >= 2);

    BSONObjIterator it(args);

    auto filePathElem = it.next();
    uassert(40341,
            "the first argument to writeFile() must be a string containing the path to the file",
            filePathElem.type() == mongo::String);

    auto fileContentElem = it.next();
    uassert(40342,
            "the second argument to writeFile() must be a string to write to the file",
            fileContentElem.type() == mongo::String);

    // Limit the capability to writing only new, regular files in existing directories.

    const boost::filesystem::path originalFilePath{filePathElem.String()};
    const boost::filesystem::path normalizedFilePath{originalFilePath.lexically_normal()};

    uassert(40343,
            "writeFile() can only write a file in a directory which already exists",
            boost::filesystem::exists(normalizedFilePath.parent_path()));
    uassert(40344,
            "writeFile() can only write to a file which does not yet exist",
            !boost::filesystem::exists(normalizedFilePath));
    uassert(40345,
            "the file name must be compatible with POSIX and Windows",
            boost::filesystem::portable_name(normalizedFilePath.filename().string()));

    std::ios::openmode mode = std::ios::out;

    auto useBinary = it.next();
    if (!useBinary.eoo()) {
        uassert(51014,
                "the third argument to writeFile(), must be a boolean indicating whether "
                "or not to read the file in binary mode. If omitted, the default is 'false'.",
                useBinary.type() == mongo::Bool);

        if (useBinary.Bool())
            mode |= std::ios::binary;
    }

    boost::filesystem::ofstream ofs{normalizedFilePath, mode};
    uassert(40346,
            str::stream() << "failed to open file " << normalizedFilePath.string()
                          << " for writing",
            ofs);

    ofs << fileContentElem.String();
    uassert(40347, str::stream() << "failed to write to file " << normalizedFilePath.string(), ofs);

    return undefinedReturn;
}

BSONObj getHostName(const BSONObj& a, void* data) {
    uassert(13411, "getHostName accepts no arguments", a.nFields() == 0);
    char buf[260];  // HOST_NAME_MAX is usually 255
    verify(gethostname(buf, 260) == 0);
    buf[259] = '\0';
    return BSON("" << buf);
}

BSONObj changeUmask(const BSONObj& a, void* data) {
#ifdef _WIN32
    uasserted(50977, "umask is not supported on windows");
#else
    uassert(50976,
            "umask takes 1 argument, the octal mode of the umask",
            a.nFields() == 1 && isNumericBSONType(a.firstElementType()));
    auto val = a.firstElement().Number();
    return BSON("" << umask(static_cast<mode_t>(val)));
#endif
}

BSONObj getFileMode(const BSONObj& a, void* data) {
    uassert(50975,
            "getFileMode() takes one argument, the absolute path to a file",
            a.nFields() == 1 && a.firstElementType() == String);
    auto pathStr = a.firstElement().checkAndGetStringData();
    boost::filesystem::path path(pathStr.rawData());
    boost::system::error_code ec;
    auto fileStatus = boost::filesystem::status(path, ec);
    if (ec) {
        uasserted(50974,
                  str::stream() << "Unable to get status for file \"" << pathStr << "\": "
                                << ec.message());
    }

    return BSON("" << fileStatus.permissions());
}

void installShellUtilsExtended(Scope& scope) {
    scope.injectNative("getHostName", getHostName);
    scope.injectNative("removeFile", removeFile);
    scope.injectNative("copyFile", copyFile);
    scope.injectNative("writeFile", writeFile);
    scope.injectNative("listFiles", listFiles);
    scope.injectNative("ls", ls);
    scope.injectNative("pwd", pwd);
    scope.injectNative("cd", cd);
    scope.injectNative("cat", cat);
    scope.injectNative("hostname", hostname);
    scope.injectNative("md5sumFile", md5sumFile);
    scope.injectNative("mkdir", mkdir);
    scope.injectNative("umask", changeUmask);
    scope.injectNative("getFileMode", getFileMode);
}
}
}
