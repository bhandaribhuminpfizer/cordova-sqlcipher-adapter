/*
 * Copyright (c) 2012-present Christopher J. Brody (aka Chris Brody)
 * Copyright (C) 2011 Davide Bertola
 *
 * This library is available under the terms of the MIT License (2008).
 * See http://opensource.org/licenses/alphabetical for full text.
 */

#import "SQLitePlugin.h"

#import "sqlite3.h"

// Defines Macro to only log lines when in DEBUG mode
#ifdef DEBUG
#   define DLog(fmt, ...) NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);
#else
#   define DLog(...)
#endif

#if !__has_feature(objc_arc)
#   error "Missing objc_arc feature"
#endif

// CustomPSPDFThreadSafeMutableDictionary interface copied from
// CustomPSPDFThreadSafeMutableDictionary.m:
//
// Dictionary-Subclasss whose primitive operations are thread safe.
@interface CustomPSPDFThreadSafeMutableDictionary : NSMutableDictionary
@end

@implementation SQLitePlugin

@synthesize openDBs;
@synthesize appDBPaths;

-(void)pluginInitialize
{
    DLog(@"Initializing SQLitePlugin");

    {
        openDBs = [CustomPSPDFThreadSafeMutableDictionary dictionaryWithCapacity:0];
        appDBPaths = [NSMutableDictionary dictionaryWithCapacity:0];

        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
        DLog(@"Detected docs path: %@", docs);
        [appDBPaths setObject: docs forKey:@"docs"];

        NSString *libs = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
        DLog(@"Detected Library path: %@", libs);
        [appDBPaths setObject: libs forKey:@"libs"];

        NSString *nosync = [libs stringByAppendingPathComponent:@"LocalDatabase"];
        NSError *err;

        // GENERAL NOTE: no `nosync` directory path entry to be added
        // to appDBPaths map in case of any isses creating the
        // required directory or setting the resource value for
        // NSURLIsExcludedFromBackupKey
        //
        // This is to avoid potential for issue raised here:
        // https://github.com/xpbrew/cordova-sqlite-storage/issues/907

        if ([[NSFileManager defaultManager] fileExistsAtPath: nosync])
        {
            DLog(@"no cloud sync directory already exists at path: %@", nosync);
        }
        else
        {
            if ([[NSFileManager defaultManager] createDirectoryAtPath: nosync withIntermediateDirectories:NO attributes: nil error:&err])
            {
                DLog(@"no cloud sync directory created with path: %@", nosync);
            }
            else
            {
                // STOP HERE & LOG WITH INTERNAL PLUGIN ERROR:
                NSLog(@"INTERNAL PLUGIN ERROR: could not create no cloud sync directory at path: %@", nosync);
                return;
            }
        }

        {
            {
                // Set the resource value for NSURLIsExcludedFromBackupKey
                NSURL *nosyncURL = [ NSURL fileURLWithPath: nosync];
                if (![nosyncURL setResourceValue: [NSNumber numberWithBool: YES] forKey: NSURLIsExcludedFromBackupKey error: &err])
                {
                    // STOP HERE & LOG WITH INTERNAL PLUGIN ERROR:
                    NSLog(@"INTERNAL PLUGIN ERROR: error setting nobackup flag in LocalDatabase directory: %@", err);
                    return;
                }

                // now ready to add `nosync` entry to appDBPaths:
                DLog(@"no cloud sync at path: %@", nosync);
                [appDBPaths setObject: nosync forKey:@"nosync"];
            }
        }
    }
}

-(id) getDBPath:(NSString *)dbFile at:(NSString *)atkey {
    if (dbFile == NULL) {
        return NULL;
    }

    NSString *dbdir = [appDBPaths objectForKey:atkey];
    if (dbdir == NULL) {
        // INTERNAL PLUGIN ERROR:
        return NULL;
    }

    NSString *dbPath = [dbdir stringByAppendingPathComponent: dbFile];
    return dbPath;
}

-(void)echoStringValue: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult * pluginResult = nil;
    NSMutableDictionary * options = [command.arguments objectAtIndex:0];

    NSString * string_value = [options objectForKey:@"value"];

    DLog(@"echo string value: %@", string_value);

    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:string_value];
    [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
}

-(void)open: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self openNow: command];
    }];
}

-(void)openNow: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];

    NSString *dbfilename = [options objectForKey:@"name"];

    NSString *dblocation = [options objectForKey:@"dblocation"];
    if (dblocation == NULL) dblocation = @"docs";
    // DLog(@"using db location: %@", dblocation);

    NSString *dbname = [self getDBPath:dbfilename at:dblocation];

    if (!sqlite3_threadsafe()) {
        // INTERNAL PLUGIN ERROR:
        NSLog(@"INTERNAL PLUGIN ERROR: sqlite3_threadsafe() returns false value");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"INTERNAL PLUGIN ERROR: sqlite3_threadsafe() returns false value"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
        return;
    } else if (dbname == NULL) {
        // INTERNAL PLUGIN ERROR - NOT EXPECTED:
        NSLog(@"INTERNAL PLUGIN ERROR (NOT EXPECTED): open with database name missing");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"INTERNAL PLUGIN ERROR: open with database name missing"];
        [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
        return;
    } else {
        NSValue *dbPointer = [openDBs objectForKey:dbfilename];

        if (dbPointer != NULL) {
            // NO LONGER EXPECTED due to BUG 666 workaround solution:
            // DLog(@"Reusing existing database connection for db name %@", dbfilename);
            NSLog(@"INTERNAL PLUGIN ERROR: database already open for db name: %@ (db file name: %@)", dbname, dbfilename);
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"INTERNAL PLUGIN ERROR: database already open"];
            [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
            return;
        }

        @synchronized(self) {
            const char *name = [dbname UTF8String];
            sqlite3 *db;

            DLog(@"open full db path: %@", dbname);

            // NOTE: create DB from resource [pre-populated] NOT supported with sqlcipher.

            if (sqlite3_open(name, &db) != SQLITE_OK) {
                [self logSqlError:db message:@"Unable to open DB"];
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unable to open DB"];
                [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
            } else {
                [self prepareDatabase:db options:options];
                // XXX Brody TODO check this in Javascript instead.
                // Attempt to read the SQLite master table [to support SQLCipher version]:
                
                Boolean databaseCheck = NO;
                if ([self checkDatabaseConnection: db dbfilename: dbfilename]) {
                    databaseCheck = YES;
                }
                
                NSString *sCipherMigrate = [options objectForKey:@"cipherMigrate"];
                Boolean cipherMigrate = sCipherMigrate ? [sCipherMigrate boolValue] : YES;
                
                if (cipherMigrate) {
                    db = [self executeCipherMigration:db name:name options:options];
                    if (db != NULL) {
                        databaseCheck = [self checkDatabaseConnection: db dbfilename: dbfilename];
                    }
                }
                
                
                if (databaseCheck) {
                    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Database opened"];
                } else {
                    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unable to open DB with key"];
                }
            }
        }
    }

    [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];

    // DLog(@"open cb finished ok");
}

-(Boolean) prepareDatabase: (sqlite3*) db options: (NSMutableDictionary*) options
{
    sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, NULL);

#if 0
    sqlite3_create_function(db, "REGEXP", 2, SQLITE_ANY, NULL, &sqlite_regexp, NULL, NULL);
#endif

    // SQLCipher key:
    NSString *dbkey = [options objectForKey:@"key"];
    const char *key = NULL;
    if (dbkey != NULL && dbkey.length != 0) key = [dbkey UTF8String];
    NSLog((key != NULL) ? @"Open DB with encryption" : @"Open DB with NO encryption");
    if (key != NULL) {
        if (sqlite3_key(db, key, strlen(key)) != SQLITE_OK) {
            [self logSqlError: db message: @"Error setting key: "];
            return NO;
        }
    }
    
    return YES;
}

-(sqlite3*) reopenDatabase: (sqlite3*) db name: (const char *) name options: (NSMutableDictionary*) options
{
    sqlite3_close(db);
    
    sqlite3* newDb;
    
    if (sqlite3_open(name, &newDb) != SQLITE_OK) {
        [self logSqlError:db message:@"Unable to open DB"];
        return NULL;
    } else {
        [self prepareDatabase:newDb options:options];
        return newDb;
    }
}

-(sqlite3*) executeCipherMigration: (sqlite3*) db name: (const char *) name options: (NSMutableDictionary*) options
{
    db = [self reopenDatabase:db name:name options:options];
    if (db == NULL) {
        NSLog(@"%@", @"Unable to reopen database for cipher migration");
        return NULL;
    } else {
        sqlite3_stmt *statement;

        sqlite3_prepare_v2(db, "PRAGMA CIPHER_MIGRATE", -1, &statement, NULL);
        
        while (sqlite3_step(statement) == SQLITE_ROW) {
            NSString *result = [[NSString alloc] initWithUTF8String:
                            (const char *) sqlite3_column_text(statement, 0)];
            NSLog(@"%@%@", @"Pragma migrate: ", result);
        }
        
        if (sqlite3_finalize(statement) != SQLITE_OK) {
            [self logSqlError:db message:@"Unable to finalize cipher migrate statement: "];
            return NULL;
        }

        db = [self reopenDatabase:db name:name options:options];
        if (db == NULL) {
            NSLog(@"%@", @"Unable to reopen database after cipher migration");
            return NULL;
        } else {
            return db;
        }
    }
}

-(void) logSqlError: (sqlite3*)db message:(NSString*) message
{
    const char *errmsg = sqlite3_errmsg(db);
    NSLog(@"%@%@", message, [NSString stringWithUTF8String:errmsg]);
}

-(Boolean) checkDatabaseConnection: (sqlite3*)db dbfilename: (NSString*) dbfilename
{
    int checkResult = sqlite3_exec(db, (const char*)"SELECT count(*) FROM _ionickv;", NULL, NULL, NULL);

    if (checkResult == SQLITE_OK) {
        NSLog(@"DB open, check sqlite master table OK");
        NSValue *dbPointer = [NSValue valueWithPointer:db];
        [openDBs setObject: dbPointer forKey: dbfilename];
        return YES;
    } else {
        [self logSqlError: db message: @"Error checking connection: "];
        return NO;
    }
}

-(void) close: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self closeNow: command];
    }];
}

-(void)closeNow: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];

    NSString *dbFileName = [options objectForKey:@"path"];

    if (dbFileName == NULL) {
        // Should not happen:
        DLog(@"No db name specified for close");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify database path"];
    } else {
        NSValue *val = [openDBs objectForKey:dbFileName];
        sqlite3 *db = [val pointerValue];

        if (db == NULL) {
            // Should not happen:
            DLog(@"close: db name was not open: %@", dbFileName);
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: Specified db was not open"];
        }
        else {
            DLog(@"close db name: %@", dbFileName);
            sqlite3_close (db);
            [openDBs removeObjectForKey:dbFileName];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"DB closed"];
        }
    }

    [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
}

-(void) delete: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self deleteNow: command];
    }];
}

-(void)deleteNow: (CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];

    NSString *dbFileName = [options objectForKey:@"path"];

    NSString *dblocation = [options objectForKey:@"dblocation"];
    if (dblocation == NULL) dblocation = @"docs";

    if (dbFileName==NULL) {
        // Should not happen:
        DLog(@"No db name specified for delete");
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify database path"];
    } else {
        NSString *dbPath = [self getDBPath:dbFileName at:dblocation];

        if (dbPath == NULL) {
            // INTERNAL PLUGIN ERROR - NOT EXPECTED:
            NSLog(@"INTERNAL PLUGIN ERROR (NOT EXPECTED): delete with no valid database path found");
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString: @"INTERNAL PLUGIN ERROR: delete with no valid database path found"];
            [self.commandDelegate sendPluginResult:pluginResult callbackId: command.callbackId];
            return;
        }

        if ([[NSFileManager defaultManager]fileExistsAtPath:dbPath]) {
            DLog(@"delete full db path: %@", dbPath);
            [[NSFileManager defaultManager]removeItemAtPath:dbPath error:nil];
            [openDBs removeObjectForKey:dbFileName];
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"DB deleted"];
        } else {
            DLog(@"delete: db was not found: %@", dbPath);
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The database does not exist on that path"];
        }
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}


-(void) backgroundExecuteSqlBatch: (CDVInvokedUrlCommand*)command
{
    [self.commandDelegate runInBackground:^{
        [self executeSqlBatchNow: command];
    }];
}

-(void) executeSqlBatchNow: (CDVInvokedUrlCommand*)command
{
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:0];
    NSMutableDictionary *dbargs = [options objectForKey:@"dbargs"];
    NSMutableArray *executes = [options objectForKey:@"executes"];

    CDVPluginResult* pluginResult;

    {
        for (NSMutableDictionary *dict in executes) {
            CDVPluginResult *result = [self executeSqlWithDict:dict andArgs:dbargs];
            if ([result.status intValue] == CDVCommandStatus_ERROR) {
                /* add error with result.message: */
                NSMutableDictionary *r = [NSMutableDictionary dictionaryWithCapacity:0];
                [r setObject:@"error" forKey:@"type"];
                [r setObject:result.message forKey:@"error"];
                [r setObject:result.message forKey:@"result"];
                [results addObject: r];
            } else {
                /* add result with result.message: */
                NSMutableDictionary *r = [NSMutableDictionary dictionaryWithCapacity:0];
                [r setObject:@"success" forKey:@"type"];
                [r setObject:result.message forKey:@"result"];
                [results addObject: r];
            }
        }

        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:results];
    }

    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(void) executeSql: (CDVInvokedUrlCommand*)command
{
    NSMutableDictionary *options = [command.arguments objectAtIndex:0];
    NSMutableDictionary *dbargs = [options objectForKey:@"dbargs"];
    NSMutableDictionary *ex = [options objectForKey:@"ex"];

    CDVPluginResult * pluginResult = [self executeSqlWithDict: ex andArgs: dbargs];

    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(CDVPluginResult*) executeSqlWithDict: (NSMutableDictionary*)options andArgs: (NSMutableDictionary*)dbargs
{
    NSString *dbFileName = [dbargs objectForKey:@"dbname"];
    if (dbFileName == NULL) {
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify database path"];
    }

    NSMutableArray *params = [options objectForKey:@"params"]; // optional

    NSValue *dbPointer = [openDBs objectForKey:dbFileName];
    if (dbPointer == NULL) {
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: No such database, you must open it first"];
    }
    sqlite3 *db = [dbPointer pointerValue];

    NSString *sql = [options objectForKey:@"sql"];
    if (sql == NULL) {
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"INTERNAL PLUGIN ERROR: You must specify a sql query to execute"];
    }

    const char *sql_stmt = [sql UTF8String];
    NSDictionary *error = nil;
    sqlite3_stmt *statement;
    int result, i, column_type, count;
    int previousRowsAffected, nowRowsAffected, diffRowsAffected;
    long long previousInsertId, nowInsertId;
    BOOL keepGoing = YES;
    BOOL hasInsertId;
    NSMutableDictionary *resultSet = [NSMutableDictionary dictionaryWithCapacity:0];
    NSMutableArray *resultRows = [NSMutableArray arrayWithCapacity:0];
    NSMutableDictionary *entry;
    NSObject *columnValue;
    NSString *columnName;
    NSObject *insertId;
    NSObject *rowsAffected;

    hasInsertId = NO;
    previousRowsAffected = sqlite3_total_changes(db);
    previousInsertId = sqlite3_last_insert_rowid(db);

    if (sqlite3_prepare_v2(db, sql_stmt, -1, &statement, NULL) != SQLITE_OK) {
        error = [SQLitePlugin captureSQLiteErrorFromDb:db];
        keepGoing = NO;
    } else if (params != NULL) {
        for (int b = 0; b < params.count; b++) {
            result = [self bindStatement:statement withArg:[params objectAtIndex:b] atIndex:(b+1)];
            if (result != SQLITE_OK) {
                error = [SQLitePlugin captureSQLiteErrorFromDb:db];
                keepGoing = NO;
                break;
            }
        }
    }

    while (keepGoing) {
        result = sqlite3_step (statement);
        switch (result) {

            case SQLITE_ROW:
                i = 0;
                entry = [NSMutableDictionary dictionaryWithCapacity:0];
                count = sqlite3_column_count(statement);

                while (i < count) {
                    columnValue = nil;
                    columnName = [NSString stringWithFormat:@"%s", sqlite3_column_name(statement, i)];

                    column_type = sqlite3_column_type(statement, i);
                    switch (column_type) {
                        case SQLITE_INTEGER:
                            columnValue = [NSNumber numberWithLongLong: sqlite3_column_int64(statement, i)];
                            break;
                        case SQLITE_FLOAT:
                            columnValue = [NSNumber numberWithDouble: sqlite3_column_double(statement, i)];
                            break;
                        case SQLITE_BLOB:
                        case SQLITE_TEXT:
                            columnValue = [[NSString alloc] initWithBytes:(char *)sqlite3_column_text(statement, i)
                                                                   length:sqlite3_column_bytes(statement, i)
                                                                 encoding:NSUTF8StringEncoding];
                            break;
                        case SQLITE_NULL:
                        // just in case (should not happen):
                        default:
                            columnValue = [NSNull null];
                            break;
                    }

                    if (columnValue) {
                        [entry setObject:columnValue forKey:columnName];
                    }

                    i++;
                }
                [resultRows addObject:entry];
                break;

            case SQLITE_DONE:
                nowRowsAffected = sqlite3_total_changes(db);
                diffRowsAffected = nowRowsAffected - previousRowsAffected;
                rowsAffected = [NSNumber numberWithInt:diffRowsAffected];
                nowInsertId = sqlite3_last_insert_rowid(db);
                if (diffRowsAffected > 0 && nowInsertId != 0) {
                    hasInsertId = YES;
                    insertId = [NSNumber numberWithLongLong:sqlite3_last_insert_rowid(db)];
                }
                keepGoing = NO;
                break;

            default:
                error = [SQLitePlugin captureSQLiteErrorFromDb:db];
                keepGoing = NO;
        }
    }

    sqlite3_finalize (statement);

    if (error) {
        return [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:error];
    }

    [resultSet setObject:resultRows forKey:@"rows"];
    [resultSet setObject:rowsAffected forKey:@"rowsAffected"];
    if (hasInsertId) {
        [resultSet setObject:insertId forKey:@"insertId"];
    }
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:resultSet];
}

-(int)bindStatement:(sqlite3_stmt *)statement withArg:(NSObject *)arg atIndex:(int)argIndex
{
    int bindResult = SQLITE_ERROR;

    if ([arg isEqual:[NSNull null]]) {
        // bind null:
        bindResult = sqlite3_bind_null(statement, argIndex);
    } else if ([arg isKindOfClass:[NSNumber class]]) {
        // bind NSNumber (int64 or double):
        NSNumber *numberArg = (NSNumber *)arg;
        const char *numberType = [numberArg objCType];

        // Bind each number as INTEGER (long long int) or REAL (double):
        if (strcmp(numberType, @encode(int)) == 0 ||
            strcmp(numberType, @encode(long long int)) == 0) {
            bindResult = sqlite3_bind_int64(statement, argIndex, [numberArg longLongValue]);
        } else {
            bindResult = sqlite3_bind_double(statement, argIndex, [numberArg doubleValue]);
        }
    } else {
        // bind NSString (text):
        NSString *stringArg;

        if ([arg isKindOfClass:[NSString class]]) {
            stringArg = (NSString *)arg;
        } else {
            stringArg = [arg description]; // convert to text
        }

        // always bind text string as UTF-8 (sqlite does internal conversion if necessary):
        NSData *data = [stringArg dataUsingEncoding:NSUTF8StringEncoding];
        bindResult = sqlite3_bind_text(statement, argIndex, data.bytes, (int)data.length, SQLITE_TRANSIENT);
    }

    return bindResult;
}

-(void)dealloc
{
    int i;
    NSArray *keys = [openDBs allKeys];
    NSValue *pointer;
    NSString *key;
    sqlite3 *db;

    /* close db the user forgot */
    for (i=0; i<[keys count]; i++) {
        key = [keys objectAtIndex:i];
        pointer = [openDBs objectForKey:key];
        db = [pointer pointerValue];
        sqlite3_close (db);
    }
}

+(NSDictionary *)captureSQLiteErrorFromDb:(struct sqlite3 *)db
{
    int code = sqlite3_errcode(db);
    int webSQLCode = [SQLitePlugin mapSQLiteErrorCode:code];
#if INCLUDE_SQLITE_ERROR_INFO
    int extendedCode = sqlite3_extended_errcode(db);
#endif
    const char *message = sqlite3_errmsg(db);

    NSMutableDictionary *error = [NSMutableDictionary dictionaryWithCapacity:4];

    [error setObject:[NSNumber numberWithInt:webSQLCode] forKey:@"code"];
    [error setObject:[NSString stringWithUTF8String:message] forKey:@"message"];

#if INCLUDE_SQLITE_ERROR_INFO
    [error setObject:[NSNumber numberWithInt:code] forKey:@"sqliteCode"];
    [error setObject:[NSNumber numberWithInt:extendedCode] forKey:@"sqliteExtendedCode"];
    [error setObject:[NSString stringWithUTF8String:message] forKey:@"sqliteMessage"];
#endif

    return error;
}

+(int)mapSQLiteErrorCode:(int)code
{
    // map the sqlite error code to
    // the websql error code
    switch(code) {
        case SQLITE_ERROR:
            return SYNTAX_ERR_;
        case SQLITE_FULL:
            return QUOTA_ERR;
        case SQLITE_CONSTRAINT:
            return CONSTRAINT_ERR;
        default:
            return UNKNOWN_ERR;
    }
}

@end /* vim: set expandtab : */
