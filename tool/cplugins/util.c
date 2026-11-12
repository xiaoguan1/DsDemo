#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <lstate.h>
#include <lobject.h>

#include <signal.h>
#include <assert.h>
#ifdef _MSC_VER
#include "sys/types.h"
#include "time.h"
#include "unistd.h"
#include "utime.h"
#include <winsock.h>
#else
#include <sys/time.h>
#include <time.h>
#include <sys/types.h>
#include <unistd.h>
#endif


#define ENCODE_CHAR_BIT   6
#define ENCODE_CHAR_BIT_E 5
#define BIT_GET(a, nb) (((a) >> (nb - 1)) & 1)

static char encode_c[65] = {
	'_',
	'0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
	'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j',
	'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
	'u', 'v', 'w', 'x', 'y', 'z',
	'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J',
	'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T',
	'U', 'V', 'W', 'X', 'Y', 'Z',
	'!', '@',
};

static char encode_ce[33] = {
	'_',
	'0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
	'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j',
	'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
	'u', 'v',
};


#include "../../skynet/skynet-src/skynet_malloc.h"

struct bit_encode_t {
	int e_mcnt;
	int e_cnt;
	char bit;
	char be_cursor;
};

void bit_encode_init(struct bit_encode_t *be, int mcnt) {
	assert(mcnt % ENCODE_CHAR_BIT == 0);
	be->e_mcnt = mcnt;
	be->e_cnt = 0;
	be->bit = 0;
	be->be_cursor = 0;
}

char bit_encode_add(struct bit_encode_t *be, char bset) {
	if(be->e_cnt >= be->e_mcnt)
		return 0;

	be->e_cnt = be->e_cnt + 1;
	be->bit = be->bit << 1;			//左移―位
	be->bit = be->bit | bset;
    be->be_cursor = be->be_cursor + 1;
    if(be->be_cursor == ENCODE_CHAR_BIT) {
        char rchar = be->bit;
        be->be_cursor = 0;
        be->bit = 0;
        return rchar + 1;
	}
    return 0;
}

void bit_encode_init_e(struct bit_encode_t *be, int mcnt) {
    assert (mcnt % ENCODE_CHAR_BIT_E == 0);
    be->e_mcnt = mcnt;
    be->e_cnt = 0;
	be->bit = 0;
    be->be_cursor = 0;
}

char bit_encode_add_e(struct bit_encode_t *be, char bset) {
	if(be->e_cnt >= be->e_mcnt)
		return 0;

	be->e_cnt = be->e_cnt + 1;
	be->bit = be->bit << 1;			//左移一位
	be->bit = be->bit | bset;
	be->be_cursor = be->be_cursor + 1;
	if (be->be_cursor == ENCODE_CHAR_BIT_E) {
		char rchar = be->bit;
		be->be_cursor = 0;
		be->bit = 0;
		return rchar + 1;
	}
	return 0;
}

int
_realclock(lua_State *L) {
#if !defined(__APPLE__) || defined(AVAILABLE_MAC_OS_X_VERSION_10_12_AND_LATER)
    struct timespec ti;
    clock_gettime(CLOCK_MONOTONIC, &ti);
    lua_pushinteger(L, ti.tv_sec);
    lua_pushinteger(L, ti.tv_nsec);
    return 2;
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    lua_pushinteger(L, tv.tv_sec);
    lua_pushinteger(L, tv.tv_usec);
    return 2;
#endif
}

int
_realtime(lua_State *L) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    lua_pushinteger(L, tv.tv_sec);
    lua_pushinteger(L, tv.tv_usec);
    return 2;
}

int
_split(lua_State *L) {
	int i = 1;
	size_t sepLen, strLen;
	const char *spliteStr = lua_tolstring(L, 1, &strLen);
	const char *spliteSep = lua_tolstring(L, 2, &sepLen);
	char *tmpStr = (char *)spliteStr;
	char *nowStr = NULL;
	size_t nowLen = 0;
	lua_newtable(L);
	if (spliteSep == NULL) {
		lua_pushlstring(L, spliteStr, strLen);
		lua_rawseti(L, -2, i++);
		return 1;
	}
	else if (!strcmp(spliteSep, "")) {
		int j;
		for (j = 0; j < strLen; ++j) {
			lua_pushlstring(L, tmpStr++, 1);
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}
	while(nowStr = strstr(tmpStr,spliteSep), nowStr != NULL){
		int len = nowStr - tmpStr;
		nowLen += len + sepLen;
		lua_pushlstring(L, tmpStr, len);
		lua_rawseti(L, -2, i++);

        if(nowLen >= strLen)
            return 1;

        tmpStr = nowStr + sepLen;
    }

    lua_pushlstring(L, tmpStr, strLen - nowLen);
    lua_rawseti(L, -2, i++);
    return 1;
}


//检测服务器handle
static uint32_t checkuid_service = 0;
//创建角色自增长的serial
static uint32_t max_uid_serial = 0;

#define UID_BIT			80                                
#define UID_INC_MAX		(1 << 3)                           
#define SID_BIT			90                                
#define SID_INC_BIT		23
#define SID_INC_MASK	(1UL << SID_INC_BIT)               

#define FID_BIT			95
#define FID_INC_BIT     33                                
#define FID_INC_MASK    (1UL << FID_INC_BIT)

#define IPPORT_SID_BIT			120                        
#define IPPORT_SID_INC_BIT		24                         
#define IPPORT_SID_INC_MASK		(1 << IPPORT_SID_INC_BIT)

#define CID_BIT                45                         
#define CID_INC_BIT            20                         
#define CID_INC_MASK           (1 << CID_INC_BIT)          

#define CORP_ID_BIT     14                                
#define CORP_ID_MAX     ((1 << CORP_ID_BIT)-  1)
#define SERVER_ID_BIT   25
#define SERVER_ID_MAX   ((1 << SERVER_ID_BIT) -1)
#define CLUSTER_ID_BIT  5
#define CLUSTER_ID_MAX	((1 << CLUSTER_ID_BIT) - 1)

// static uint32_t u_lsec = 0;
// static uint32_t u_lusec = 0;
// static uint32_t u_inc = 0;

static void
puch_encode(struct bit_encode_t *be, uint64_t ei, char *encode_char, int s_i, int mc_cnt, int *c_i_p) {
	int i = 0;
	for (i = s_i; i >= 1; --i) {
		unsigned char c = bit_encode_add(be, BIT_GET(ei, i));
		if (c > 0 && (*c_i_p) < mc_cnt) {
			encode_char[(*c_i_p)] = encode_c[c];
			(*c_i_p) = (*c_i_p) + 1;
		}
	}
}

static void
puch_encode_e(struct bit_encode_t *be, uint64_t ei, char *encode_char, int s_i, int mc_cnt, int *c_i_p) {
	int i = 0;
	for (i = s_i; i >= 1; --i) {
		unsigned char c = bit_encode_add_e(be, BIT_GET(ei, i));
		if (c > 0 && (*c_i_p) < mc_cnt) {
			encode_char[(*c_i_p)] = encode_ce[c];
			(*c_i_p) = (*c_i_p) + 1;
		}
	}
}

int
_set_checkuid_service(lua_State *L) {
	if (checkuid_service != 0) {
		luaL_error(L, "has set checkuid_service!!!");
	}
	uint32_t service_id = luaL_checkinteger(L, -1);
	checkuid_service = service_id;
	return 0;
}
int
_set_max_uid_serial(lua_State *L) {
	if (max_uid_serial != 0) {
		luaL_error(L, "has set max_uid_serial!!!");
	}
	uint32_t serial_id = luaL_checkinteger(L, -1);
	max_uid_serial = serial_id;
	return 0;
}

//这个也只能在login service中处理
int
_new_uid(lua_State *L) {				// server_id:20,inc_no:30
	if (checkuid_service == 0) {
       luaL_error(L, "set checkuidservice first!!!");
	}
	int64_t server_id = luaL_checkinteger(L, -2);		//serverid
	int64_t service_id = luaL_checkinteger(L, -1);		//serviceid
	if (checkuid_service != service_id) {
       luaL_error(L, "this service can not use new_uid func!!!");
	}
	//为断服务器idS否超过了
	if (server_id > SERVER_ID_MAX) {
       luaL_error(L, "server_id must not bigger than %d", SERVER_ID_MAX);
	}

	uint32_t sec = 0;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	sec = tv.tv_sec;

	uint32_t uid_serial = __sync_add_and_fetch(&max_uid_serial, 1);
	uid_serial = uid_serial % SID_INC_MASK;

	struct bit_encode_t be;
	bit_encode_init_e(&be, 80);
	int mc_cnt = 80 / ENCODE_CHAR_BIT_E;
	char encode_char[mc_cnt];
	memset(encode_char, 0, mc_cnt);

	int c_i = 0;
	// sec:32,serverId:25,uid_serial:23
	puch_encode_e(&be, sec, encode_char, 32, mc_cnt, &c_i);
	puch_encode_e(&be, server_id, encode_char, SERVER_ID_BIT, mc_cnt, &c_i);
	puch_encode_e(&be, uid_serial, encode_char, SID_INC_BIT, mc_cnt, &c_i);
	lua_pushlstring(L, encode_char, mc_cnt);
    return 1;
}

static uint64_t _fight_id= 0;
int
_new_sfigntid(lua_State *L) {
    uint64_t server_id = luaL_checkinteger(L, -2);		//serverid
    uint64_t cluster_id = luaL_checkinteger(L, -1);		//clusterid   街个cluster必须配一个id,这样才能分布式也唯一

	// 判新服务器id是否超过了
	if (server_id > SERVER_ID_MAX) {
       luaL_error(L, "server_id must not bigger than %d", SERVER_ID_MAX);
	}
	// 判断集群id是否超过了
    if (cluster_id > CLUSTER_ID_MAX) {
       luaL_error(L, "cluster_id must not bigger than %d", CLUSTER_ID_MAX);
	}

	uint32_t sec = 0;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	sec = tv.tv_sec;

	uint64_t f_id = __sync_add_and_fetch(&_fight_id, 1);

	struct bit_encode_t be;
	bit_encode_init_e(&be, FID_BIT);
	int mc_cnt = FID_BIT / ENCODE_CHAR_BIT_E;
#ifdef _MSC_VER
	char encode_char[FID_BIT / ENCODE_CHAR_BIT_E + 1];
#else
	char encode_char[mc_cnt + 1];
#endif
	memset(encode_char, 0, mc_cnt + 1);

	int c_i = 0;
	// server_id:25,time_sec:32,cluster_id:5,inc_no:33
	puch_encode_e(&be, server_id, encode_char, SERVER_ID_BIT, mc_cnt, &c_i);
	puch_encode_e(&be, sec, encode_char, 32, mc_cnt, &c_i);
	puch_encode_e(&be, cluster_id, encode_char, CLUSTER_ID_BIT, mc_cnt, &c_i);
	puch_encode_e(&be, f_id, encode_char, FID_INC_BIT, mc_cnt, &c_i);

	lua_pushlstring(L, encode_char, mc_cnt);
	return 1;
}

static uint32_t _ipport_s_id = 0;
//此处有锁,同一节点内的都能用,1秒内创建1677万个
int
_new_ipport_sid(lua_State *L) {
	uint64_t ipport_no = luaL_checkinteger(L, -1);

	uint32_t sec = 6;
	uint32_t usec = 0;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	sec = tv.tv_sec;
	usec = tv.tv_usec;

	uint32_t s_id = __sync_add_and_fetch(&_ipport_s_id, 1);
	s_id = s_id % IPPORT_SID_INC_MASK;

	struct bit_encode_t be;
	bit_encode_init(&be, IPPORT_SID_BIT);
	int mc_cnt = IPPORT_SID_BIT / ENCODE_CHAR_BIT;
#ifdef _MSC_VER
	char encode_char[IPPORT_SID_BIT / ENCODE_CHAR_BIT + 1];
#else
	char encode_char[mc_cnt + 1];
#endif
	memset(encode_char, 0, mc_cnt + 1);

	int c_i = 0;
	//ipport_no:48,time_sec:32,inc_no:24,time_msec:16
	puch_encode(&be, ipport_no, encode_char, 48, mc_cnt, &c_i);
	puch_encode(&be, sec, encode_char, 32, mc_cnt, &c_i);
	puch_encode(&be, s_id, encode_char, IPPORT_SID_INC_BIT, mc_cnt, &c_i);
	puch_encode(&be, usec, encode_char, 16, mc_cnt, &c_i);

	lua_pushlstring(L, encode_char, mc_cnt);
	return 1;
}

// 由逻精提供club_id,每个不同节点可以创建16777216个(这里只是为了优化缩减字符串而用)
int
_new_ipport_cid(lua_State *L) {
	uint64_t server_id = luaL_checkinteger(L, -2);
	uint64_t club_id = luaL_checkinteger(L, -1);

	// 判断帮派id是否超过了
	if (club_id > CID_INC_MASK) {
		luaL_error(L, "club_id must not bigger than %d", CID_INC_MASK);
	}
	// 判断服务器id是否超过了
	if(server_id > SERVER_ID_MAX) {
		luaL_error(L, "server_id must not bigger than %d", SERVER_ID_MAX);
	}

	struct bit_encode_t be;
	bit_encode_init_e(&be, CID_BIT);
	int mc_cnt = CID_BIT / ENCODE_CHAR_BIT_E;
#ifdef _MSC_VER
	char encode_char[CID_BIT / ENCODE_CHAR_BIT_E + 1];
#else
	char encode_char[mc_cnt + 1];
#endif
	memset(encode_char, 9, mc_cnt + 1);

	int c_i = 0;
	// server_id:25,inc_no:20
	puch_encode_e(&be, server_id, encode_char, SERVER_ID_BIT, mc_cnt, &c_i);
	puch_encode_e(&be, club_id, encode_char, CID_INC_BIT, mc_cnt, &c_i);

   lua_pushlstring(L, encode_char, mc_cnt);
   return 1;
}

static uint64_t _s_id = 0;
// 此处有锁，同一节点内的都能用,1秒内创建268435456个
int							// server_id:25,time_sec:32,cluster_id:5,inc_no:28
_new_sid(lua_State *L) {
	uint64_t server_id = luaL_checkinteger(L, -2);		//serverid
	uint64_t cluster_id = luaL_checkinteger(L, -1);		//clusterid 每个cluster必须配一个id,这样才能分布式也唯一

	//判断服务器id是否超过了
	if (server_id > SERVER_ID_MAX) {
		luaL_error(L, "server id must not bigger than %d", SERVER_ID_MAX);
	}
	//判断集群id是否超过了
	if(cluster_id > CLUSTER_ID_MAX) {
		luaL_error(L, "club_id must not bigger than %d", CLUSTER_ID_MAX);
	}

	uint32_t sec = 0;
	struct timeval tv;
	gettimeofday(&tv, NULL);
	sec = tv.tv_sec;

	uint32_t s_id = __sync_add_and_fetch(&_s_id, 1);
	s_id = s_id % SID_INC_MASK;

	struct bit_encode_t be;
	bit_encode_init_e(&be, SID_BIT);
	int mc_cnt = SID_BIT / ENCODE_CHAR_BIT_E;
#ifdef _MSC_VER
	char encode_char[SID_BIT / ENCODE_CHAR_BIT_E + 1];
#else
	char encode_char[mc_cnt + 1];
#endif
	memset(encode_char, 0, mc_cnt + 1);

	int c_i = 0;
	// server_id:25,time_sec:32,cluster_id:5,inc_no:23
	puch_encode_e(&be, server_id, encode_char, SERVER_ID_BIT, mc_cnt, &c_i);
	puch_encode_e(&be, sec, encode_char, 32, mc_cnt, &c_i);
	puch_encode_e(&be, cluster_id, encode_char, CLUSTER_ID_BIT, mc_cnt, &c_i);
	puch_encode_e(&be, s_id, encode_char, SID_INC_BIT, mc_cnt, &c_i);

	lua_pushlstring(L, encode_char, mc_cnt);
	return 1;
}

static uint64_t _schar_id = 0;
int
_new_scharid(lua_State *L) {
	uint64_t no = luaL_checkinteger(L, -4);				// no 防止宕机后id一样导致玩家对象id复用了
	uint64_t random = luaL_checkinteger(L, -3);			// 随机数
	uint64_t server_id = luaL_checkinteger(L, -2);		// serverid
	uint64_t cluster_id = luaL_checkinteger(L, -1);		// clusterid 每个cluster必须配一个id，这样才能分布式也唯一
	uint64_t char_id = __sync_add_and_fetch(&_schar_id, 1);

	//判断眼务器id是否超过了
	if (server_id > SERVER_ID_MAX) {
		luaL_error(L, "server_id must not bigger than %d", SERVER_ID_MAX);
	}
	//判断集群id否超过了
	if (cluster_id > CLUSTER_ID_MAX) {
		luaL_error(L, "clustered must not bigger than %d", CLUSTER_ID_MAX);
	}

	//16位服编号,5位cluster, 34位id
	struct bit_encode_t be;
	bit_encode_init_e(&be, 70);
	int mc_cnt = 70 / ENCODE_CHAR_BIT_E;
#ifdef _MSC_VER
	char encode_char[70 / ENCODE_CHAR_BIT_E + 1];
#else
	char encode_char[mc_cnt + 1];
#endif
	memset(encode_char, 0, mc_cnt + 1);

	int c_i = 0;
	//no:3,random:5,server_id:25,cluster_id:5,char_id:32
	puch_encode_e(&be, no, encode_char, 3, mc_cnt, &c_i);
	puch_encode_e(&be, random, encode_char, 5, mc_cnt, &c_i);
	puch_encode_e(&be, server_id, encode_char, SERVER_ID_BIT, mc_cnt, &c_i);
	puch_encode_e(&be, cluster_id, encode_char, CLUSTER_ID_BIT, mc_cnt, &c_i);
	puch_encode_e(&be, char_id, encode_char, 32, mc_cnt, &c_i);
	lua_pushlstring(L, encode_char, mc_cnt);

	return 1;
}

// #define CHARID_SERVER_MOVE (63 - 14)
// #define CHARID_CLUSTER_MOVE (63 - 14 - 10)
// #define CHARID_MASS              ((IL << 39) - 1)
// static uint64_t _char_id = 0;
// int
// _new_charid(lua_State *L) {
// uint64_t server_id = luaL_checkinteger(L, -2); //serverid
// uint64_t clustered = luaL_checkinteger(L, -1); //clusterid	每个cluster必须配一个id,这样才能分布式也唯一
// uint64_t char_id = —sync_add_and_Fetch(&_char_id, 1);

// //1位符号位,14位服编号,10位cluster, 39位id
// uint64_t nchar_id = (server_id << CHARID_SERVER_MOVE) | (cluster_id << CHARID_CLUSTER_MOVE) | (char_id & CHARID_MASS);
// lua_pushinteger(L, nchar_id);
// return 1;
// }

static size_t _idx_id = 0;
int
_new_index(lua_State *L) {
	size_t idx_id = __sync_add_and_fetch(&_idx_id, 1);
	lua_pushinteger(L, idx_id);
	return 1;
}

static uint64_t _item_serial = 0;
int									//time_min:24(这里记录的是分钟数),server_id:20,inc_no:20(20位也就是最大1048575,一分钟内不能超过这个值)
_new_item_index(lua_State *L) {
	uint64_t time_sec = luaL_checkinteger(L, -2);	// 当前时间
	uint64_t server_id = luaL_checkinteger(L, -1);	//serverid

	// 判断服务器id是否超过了
	if (server_id > SERVER_ID_MAX) {
		luaL_error(L, "server_id must not bigger than %d", SERVER_ID_MAX);
	}

    // 转化为分钟
    uint64_t time_min = time_sec / 60;
    uint64_t item_serial = __sync_add_and_fetch(&_item_serial, 1);
    item_serial = item_serial % SID_INC_MASK;
    uint64_t get_serial = (time_min << 40) | (server_id << 44 >> 24) | item_serial;
	lua_pushinteger(L, get_serial);
	return 1;
}

int
_strhash(lua_State *L) {
	size_t strLen;
	int i = 0;
	uint32_t h = 0;
	const char *str = lua_tolstring(L, -2, &strLen);
	uint32_t hashnum = lua_tointeger(L, -1);
	for ( i = strLen - 1; i >= 0; i--){
		h += str[i];
	}
	h = h % hashnum + 1;
	lua_pushinteger(L, h);
	return 1;
}

static void *pb_env = NULL;

int
_get_pbenv(lua_State *L) {
	if (pb_env) {
		lua_pushlightuserdata(L, pb_env);
	} else {
		lua_pushnil(L);
	}
	return 1;
}

int
_add_pbenv(lua_State *L) {
	// if (pb_env) {
	// 	return 0;		// 已经有了pb
	// }
	pb_env = lua_touserdata(L, -1);
	return 0;
}

int
_load_pbenv(lua_State *L) {
	if (!pb_env) {
		luaL_error(L, "not pb_env");
	}
	lua_getglobal(L, "debug");
	if(!lua_istable(L, -1))
		luaL_error(L, "load_pbenv not debug");
	lua_getfield(L, -1, "getregistry");
	if(!lua_isfunction(L, -1))
		luaL_error(L, "load_pbenv not debug.getregistry function");
	lua_call(L, 0, 1);
	if(!lua_istable(L, -1))
		luaL_error(L, "load_pbenv not debug.getregistry() table");

	lua_pushliteral(L, "PROTOBUF_ENV");
	lua_pushlightuserdata(L, pb_env);
	lua_settable(L, -3);

	return 0;
}

int
_pbc_splite(lua_State *L) {
	unsigned char *s = (unsigned char *)lua_touserdata(L, -1);
	int proto_id = (s[0] << 8) + s[1];
	lua_pushinteger(L, proto_id);
	lua_pushlightuserdata(L, s + 2);
	return 2;
}

static const char *
_tolstring(lua_State *L, size_t *sz, int index) {
	const char * ptr;
	if (lua_isuserdata(L,index)) {
		ptr = (const char *)lua_touserdata(L,index);
		*sz = (size_t)luaL_checkinteger(L, index+1);
	} else {
		ptr = luaL_checklstring(L, index, sz);
	}
	return ptr;
}

static int
_pack(lua_State *L) {
	size_t len;
	const char * ptr = _tolstring(L, &len, 1);
	uint8_t lb[2];
	luaL_Buffer buffer;
	luaL_buffinit(L, &buffer);

	lb[0] = (len >> 8) & 0xff;
	lb[1] = len & 0xff;
	luaL_addlstring(&buffer, (void *)lb, 2);
	luaL_addlstring(&buffer, ptr, len);

	luaL_pushresult(&buffer);
	lua_pushinteger(L, len + 2);

	return 2;
}

static int
_new_arraytbl(lua_State *L) {
	int aCnt = luaL_checkinteger(L, -1);
	lua_createtable(L, aCnt, 0);
	return 1;
}

static int
_new_rectbl(lua_State *L) {
	int rCnt = luaL_checkinteger(L, -1);
	lua_createtable(L, 0, rCnt);
	return 1;
}

#ifdef _MSC_VER
#define MAX_PRINT_LEN 102400
//转换文字编码为ASC
static size_t convertToACP(const char* msg, const size_t len, char* buf, const size_t buf_len)
{
    static WCHAR wbuf[MAX_PRINT_LEN + 1];
    int cch = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, msg, __min((int)len, MAX_PRINT_LEN), wbuf, sizeof(wbuf) - 1);

    if (cch > 0)
    {
        cch = WideCharToMultiByte(CP_ACP, 0, wbuf, __min(cch, MAX_PRINT_LEN), buf, buf_len, NULL, NULL);

        if (cch > 0)
		{
			buf[cch] = 0;
			return cch;
		}
	}
	//本身就是ACP
	else
	{
		cch = (int)(__min(buf_len - 1, len));
		memcpy(buf, msg, cch);
		buf [cch] = 0;
		return cch;
	}

    return 0;
}
#endif

static void
_print(lua_State *L) {
	int i = 0;
	int n = lua_gettop(L); /* 参数的个数 */
	for (i = 1; i <= n; i++) {
		int t = lua_type(L, i);
		const void *ptr = NULL;
		switch (t) {
			case LUA_TNIL:
				printf("nil");
				break;
			case LUA_TNUMBER: {
				if (lua_isinteger(L, i)) {
					lua_Integer x = lua_tointeger(L, i);
					printf("%lld", x);
				} else {
					lua_Number n = lua_tonumber(L, i);
					printf("%.14g", n);
				}
				break;
			}
			case LUA_TBOOLEAN:
				if (lua_toboolean(L, i)) {
					printf("true");
				} else {
					printf("false");
					}
				break;
            case LUA_TSTRING:
			{
                const char* log_msg = lua_tostring(L, i);
#ifdef _MSC_VER
                // 转换为ASC编码
                static char msg_buf[MAX_PRINT_LEN + 1];
				size_t msg_len = convert!oACP(log ntsg, 5trlen(log_msg), msg_buf, MAX^PRINT_LEN);
				printf, msg_buf);
				if (1== n)
				{
					printf("\n")
				}
#else
				printf("%s", log_msg);
#endif
				break;
			}
			case LUA_TTABLE:
				ptr = lua_topointer(L, i);
				printf("table :%p", ptr);
				break;
			case LUA_TFUNCTION:
				ptr = lua_topointer(L, i);
				printf("function :%p", ptr);
				break;
			case LUA_TUSERDATA:
				ptr = lua_topointer(L, i);
				printf("userdata :%p", ptr);
				break;
			case LUA_TTHREAD:
				ptr = lua_topointer(L, i);
				printf("thread :%p", ptr);
				break;
			case LUA_TLIGHTUSERDATA:
				ptr = lua_topointer(L, i);
				printf("lightuserdata :%p", ptr);
				break;
			default:
				ptr = lua_topointer(L, i);
				printf("unknow :%p", ptr);
				break;
		}
		if (i < n)
		{
			printf(" ");
		}
	}
}

static int
print_info(lua_State *L) {
#ifndef _MSC_VER
	printf("\033[42;39m");
#endif
	_print(L);
#ifndef _MSC_VER
	printf("\033[0m\n");
#endif
	return 0;
}

static int
print_warn(lua_State *L) {
#ifndef _MSC_VER
	printf("\033[43;39m");
#endif
	_print(L);
#ifndef _MSC_VER
	printf("\033[0m\n");
#endif
	return 0;
}

static int
print_error(lua_State *L) {
#ifndef _MSC_VER
	printf("\033[41;39m");
#endif
	_print(L);
#ifndef _MSC_VER
	printf("\033[0m\n");
#endif
	return 0;
}

static int
print_debug(lua_State *L) {
#ifndef _MSC_VER
	printf("\033[45;39m");
#endif
	_print(L);
#ifndef _MSC_VER
	printf("\033[0m\n");
#endif
	return 0;
}

static int
battle_tonumber(lua_State *L) {
	size_t strLen;
	const char *str = lua_tolstring(L, -1, &strLen);
	if (str && strLen > 0) {
		int d = atoi(str);
		lua_pushinteger(L, d);
		return 1;
	} else {
		lua_pushnil(L);
		return 1;
	}
}


int
luaopen_util_core(lua_State *L) {
    // get_ip();

	luaL_checkversion(L);
	luaL_Reg l[] = {
		{ "realclock", _realclock },
		{ "realtime", _realtime },
		{ "split", _split },
		{ "set_checkuid_service", _set_checkuid_service },
		{ "set_max_uid_serial", _set_max_uid_serial },
		{ "new_uid", _new_uid },					//全平台唯一，可以跨平台(生产玩家唯一uid)
		{ "new_sid", _new_sid },					//全平台唯一，可以跨平台(但是合服没corp_id会有问题)
		{ "new_ipport_sid", _new_ipport_sid },		//全平台唯一，可以跨平台(也可以合服)
		{ "new_ipport_cid", _new_ipport_cid },		//全平台唯一，可以跨平台(也可以合服)
		// { "new_charid", _new_charid },			//能在整个平台中用,跨服,不跨平台
		{ "new_scharid", _new_scharid },			//能在整个平台中用,跨服,不跨平台(10位字符串)
		{ "new_index", _new_index },				//这个无需修改，只能在skynet进程内使用
		{ "new_item_index", _new_item_index },		//这个无需修改，只能在skynet进程内使用
		{ "new_sfigntid", _new_sfigntid },			//全平台唯一，可以跨平台（也可以合服）
		{ "strhash", _strhash },
		{ "add_pbenv", _add_pbenv },
		{ "load_pbenv", _load_pbenv },
		{"get_pbenv", _get_pbenv},
		{ "pbc_splite", _pbc_splite },
		{ "pack", _pack },
		{ "new_arraytbl", _new_arraytbl },
		{ "new_rectbl", _new_rectbl },
		{ "print_info", print_info },
		{ "print_warn", print_warn },
		{ "print_error", print_error },
		{ "print_debug", print_debug },
		{ "battle_tonumber", battle_tonumber },
		{ NULL, NULL },
	};
	luaL_newlib(L, l);
	return 1;
}