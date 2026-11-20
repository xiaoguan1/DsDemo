#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#include "../../skynet/skynet-src/skynet.h"
// #include "../lua-limit/llimit.h"

#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <assert.h>
#include <stdbool.h>

#define SESSION_MASK	0x7fffffff
#define NODE_MAX_LEN	40
#define ADDR_MAX_LEN	20
#define TEMP_LENGTH		0X8200
#define MULTI_PART		0x8000

#define MULTI_F 		0x41
#define MULTI_M 		0x42
#define MULTI_E 		0x44

#ifdef _MSC_VER
#define COMPATIBLE_INLINE __inline
#else
#define COMPATIBLE_INLINE inline
#endif

static uint32_t n_session = 0;

static void
fill_uint8(uint8_t *buf, uint8_t n) {
	buf[0] = n & 0xff;
}

static void
fill_uint32(uint8_t *buf, uint32_t n) {
	buf[0] = n & 0xff;
	buf[1] = (n >> 8) & 0xff;
	buf[2] = (n >> 16) & 0xff;
	buf[3] = (n >> 24) & 0xff;
}

static void
fill_header(uint8_t *buf, int sz) {
	assert(sz < 0x10000);
	buf[0] = (sz >> 8) & 0xff;
	buf[1] = sz & 0xff;
}

static COMPATIBLE_INLINE uint32_t
unpack_uint32(const uint8_t *buf) {
	return buf[0] | buf[1] << 8 | buf[2] << 16 | buf[3] << 24;
}

static void
pack_multi(lua_State *L, uint32_t session, const char *node, size_t node_sz, void *msg, uint32_t sz) {
	// multinfo, session, node, msg
	uint8_t buf[TEMP_LENGTH];
	int part = (sz - 1) / MULTI_PART + 1;
	int i;
	char *ptr = msg;
	for (i = 0; i < part; ++i) {
		uint32_t s;
		if (sz > MULTI_PART) {
			s = MULTI_PART;
			fill_uint8(buf + 2, MULTI_M);
		} else {
			s = sz;
			fill_uint8(buf + 2, MULTI_E);
		}
		fill_header(buf, 6 + node_sz + s);			//I 4-4 + l(node_len) + node_sz + s
		fill_uint32(buf + 3, session);				//session
		fill_uint8(buf + 7, (uint8_t)node_sz);		//node长度
		memcpy(buf + 8, node, node_sz);				//node

		memcpy(buf + 8 + node_sz, ptr, s);
		lua_pushlstring(L, (const char *)buf, s + 8 + node_sz);

		lua_rawseti(L, -2, i + 1);					// 放到mult table索引为i + 1的地方 mtbl[i + 1] = lua_pushlstring
		sz -= s;
		ptr += s;
	}
}

static int
pack_addrn(lua_State *L, uint32_t session, void *msg, uint32_t sz, bool is_free) {
	// multinfo, session, node, addr, type, msg
	// multinfo, session, node, msg

	size_t node_sz = 0;
	const char *node = lua_tolstring(L, 2, &node_sz);
	if (node_sz >= NODE_MAX_LEN || node_sz <= 0) {
		if (is_free) {
			skynet_free(msg);
		}
		luaL_error(L, "node too long:%s len:%d", node, node_sz);
	}
	uint32_t addr = luaL_checkinteger(L, 3);
	int type = luaL_checkinteger(L, 4);

	if (sz < MULTI_PART) {
#ifdef _MSC_VER
		assert(NODE_MAX_LEN + sz <= 65535);
		uint8_t buf[65535 + 50];
#else
		uint8_t buf[NODE_MAX_LEN + sz + 50];
#endif
		/**
		 * 格式：整包长度(2个字节) | 数据包类型(0:单包) | session会话(4个字节) | 节点信息长度(1个字节) | 节点信息内容(node_sz个字节) | addr服务地址类型(1个字节，0：为数值型) | addr服务地址(4个字节) | 消息类型(4个字节，高8位rpc行为、低8位lua服务协议) | 消息内容msg(sz个字节)
		 * 
		 * 长度：2字节 | 1字节 | 4字节 | 1字节 | node_sz字节 | 1字节 | 4字节 | 4字节 | msg的sz字节
		*/

		fill_header(buf, 15 + node_sz + sz);	//1 + 4 + 1(node_len) + node_sz + 1(addr type) + 4 + 4 + sz
		fill_uint8(buf + 2, 0);					//单个发送
		fill_uint32(buf + 3, session);			//session
		fill_uint8(buf + 7, (uint8_t)node_sz);	//node长度
		memcpy(buf + 8, node, node_sz);			//node
		fill_uint8(buf + 8 + node_sz, 0);		//表示addr是数值
		fill_uint32(buf + 9 + node_sz, addr);	//addr
		fill_uint32(buf + 13 + node_sz, type);	//type
		memcpy(buf + 17 + node_sz, msg, sz);	//msg

		lua_pushlstring(L, (const char *)buf, sz + 17 + node_sz);
		lua_pushinteger(L, session);
		if (is_free) {
			skynet_free(msg);					//释放内存
		}
		return 2;
	} else {
		uint8_t buf[NODE_MAX_LEN + 50];
		fill_header(buf, 19 + node_sz);			//1 + 4 + 1(node_len) + node_sz + 1(addr type) + 4 + 4 + 4
		fill_uint8(buf + 2, MULTI_F);			//多发第一个
		fill_uint32(buf + 3, session);			//session
		fill_uint8(buf + 7, (uint8_t)node_sz);	//node长度
		memcpy(buf + 8, node, node_sz);			//node
		fill_uint8(buf + 8 + node_sz, 0);		//表示addr是数值
		fill_uint32(buf + 9 + node_sz, addr);	//addr
		fill_uint32(buf + 13 + node_sz, type);	//type
		fill_uint32(buf + 17 + node_sz, sz);	//sz

		lua_pushlstring(L, (const char *)buf, 21 + node_sz);
		lua_pushinteger(L, session);

		int multipak = (sz - 1) / MULTI_PART + 1;
		lua_createtable(L, multipak, 0);
		pack_multi(L, session, node, node_sz, msg, sz);

		if (is_free) {
			skynet_free(msg);
		}
		return 3;
	}
}

static int
pack_addrs(lua_State *L, uint32_t session, void *msg, uint32_t sz, bool is_free) {
	// multinfo, session, node, addr, type, msg
	// multinfo, session, node, msg

	size_t node_sz = 0;
	const char *node = lua_tolstring(L, 2, &node_sz);
	if (node_sz >= NODE_MAX_LEN || node_sz <= 0) {
		if (is_free) {
			skynet_free(msg);
		}
		luaL_error(L, "node too long:%s len:%d", node, node_sz);
	}
	size_t addr_sz = 0;
	const char *addr = lua_tolstring(L, 3, &addr_sz);
	if (addr_sz >= ADDR_MAX_LEN) {
		if (is_free) {
			skynet_free(msg);
		}
		luaL_error(L, "addr too long:%s len:%d", addr, addr_sz);
	}
	int type = luaL_checkinteger(L, 4);

	if (sz < MULTI_PART) {
#ifdef _MSC_VER
		assert(NODE_MAX_LEN + ADDR_MAX_LEN + sz <= 65535);
		uint8_t buf[65535 + 50];
#else
		uint8_t buf[NODE_MAX_LEN + ADDR_MAX_LEN + sz + 50];
#endif
		fill_header(buf, 12 + node_sz + addr_sz + sz);		//1 + 4 + 1(node_len) + node_sz + 1(addr type) + 1(addr_len) - addr_sz + 4 + sz
		fill_uint8(buf + 2, 0);								//单个发送
		fill_uint32(buf + 3, session);						//session
		fill_uint8(buf + 7, (uint8_t)node_sz);				//node长度
		memcpy(buf + 8, node, node_sz);						//node
		fill_uint8(buf + 8 + node_sz, 1);					//表示addr是数值
		fill_uint8(buf + 9 + node_sz, (uint8_t)addr_sz);	//addr长度
		memcpy(buf + 10 + node_sz, addr, addr_sz);			//addr
		fill_uint32(buf + 10 + node_sz + addr_sz, type);	//type
		memcpy(buf + 14 + node_sz + addr_sz, msg, sz);		//msg

		lua_pushlstring(L, (const char *)buf, sz + 14 + node_sz + addr_sz);
		lua_pushinteger(L, session);

		if (is_free) {
			skynet_free(msg);								//释放内存
		}
		return 2;
	} else {
		uint8_t buf[NODE_MAX_LEN + ADDR_MAX_LEN + 50];
		fill_header(buf, 16 + node_sz + addr_sz);			//1 + 4 + 1(node_len) + node_sz + 1(addr type) + 1(addr_len) - addr_sz + 4 + 4
		fill_uint8(buf + 2, MULTI_F);						//多发第一个
		fill_uint32(buf + 3, session);						//session
		fill_uint8(buf + 7, (uint8_t)node_sz);				//node长度
		memcpy(buf + 8, node, node_sz);						//node
		fill_uint8(buf + 8 + node_sz, 1);					//表示addr是数值
		fill_uint8(buf + 9 + node_sz, (uint8_t)addr_sz);	//addr长度
		memcpy(buf + 10 + node_sz, addr, addr_sz);			//addr
		fill_uint32(buf + 10 + node_sz + addr_sz, type);	//type
		fill_uint32(buf + 14 + node_sz + addr_sz, sz);		//sz

		lua_pushlstring(L, (const char *)buf, 18 + node_sz + addr_sz);
		lua_pushinteger(L, session);

		int multipak = (sz - 1) / MULTI_PART + 1;
		lua_createtable(L, multipak, 0);
		pack_multi(L, session, node, node_sz, msg, sz);

		if (is_free) {
			skynet_free(msg);
		}
		return 3;
	}
}

static int
lpack(lua_State *L) {		//非线程安全
	void *m_data = lua_touserdata(L, 5);
	if (m_data == NULL) {
		return luaL_error(L, "invalid request message");
	}
	uint32_t m_sz = (uint32_t)luaL_checkinteger(L, 6);

	uint32_t s = 0;
	if (lua_isnil(L, 1)) {
		n_session = n_session % SESSION_MASK + 1;
		s = n_session;
	} else
		s = luaL_checkinteger(L, 1);

	if (lua_type(L, 3) == LUA_TNUMBER) {
		return pack_addrn(L, s, m_data, m_sz, true);
	} else {
		return pack_addrs(L, s, m_data, m_sz, true);
	}
}

static int
lpack_nf(lua_State *L) {		//非线程安全
	void *m_data = lua_touserdata(L, 5);
	if (m_data == NULL) {
		return luaL_error(L, "invalid request message");
	}
	uint32_t m_sz = (uint32_t)luaL_checkinteger(L, 6);

	uint32_t s = 0;
    if (lua_isnil(L, 1)) {
        n_session = n_session % SESSION_MASK + 1;
        s = n_session;
    } else
        s = luaL_checkinteger(L, 1);

    if (lua_type(L, 3) == LUA_TNUMBER) {
        return pack_addrn(L, s, m_data, m_sz, false);
    } else {
        return pack_addrs(L, s, m_data, m_sz, false);
	}
}

static int
unpack_one(lua_State *L, const uint8_t *buf, size_t sz) {
	// multinfo, session, node, addr, type, msg
	if (sz <= 7) {
		luaL_error(L, "unpack_one invalid package 1 size:%d, csize:%d", sz, 7);
	}
	lua_pushinteger(L, (uint32_t)buf[0]);											//multinfo
	lua_pushinteger(L, unpack_uint32(buf + 1));										//session
	uint8_t node_sz = buf[5];
	if (node_sz <= 0) {
		luaL_error(L, "unpack_one invalid node_sz:%d", node_sz);
	}
	if (sz <= 7 + node_sz) {			// 后面if else最低都是7
		luaL_error(L, "unpack_one invalid package 2 size:%d, csize:%d", sz, 7 + node_sz);
	}
	lua_pushlstring(L, (const char *)buf + 6, node_sz);							//node
	uint8_t addr_type = buf[6 + node_sz];										//addr_type
	if (addr_type == 0) {
		if (sz < 15 + node_sz) {		// 信息可以空，所以<
			luaL_error(L, "unpack_one invalid package 3 size:%d, csize:%d", sz, 15 + node_sz);
		}
		lua_pushinteger(L, unpack_uint32(buf + 7 + node_sz));					//addr
		lua_pushinteger(L, unpack_uint32(buf + 11 + node_sz));					//type

		char *msg = skynet_malloc(sz - 15 - node_sz);
		memcpy(msg, (const char *)buf + 15 + node_sz, sz - 15 - node_sz);
		lua_pushinteger(L, sz - 15 - node_sz);									//sz
		lua_pushlightuserdata(L, msg);											//msg
		return 7;
	} else {
		uint8_t addr_sz = buf[7 + node_sz];		//可以没有，回应的时候是没有的
		if (sz < 12 + node_sz + addr_sz) {		// 信息可以空，所以<
			luaL_error(L, "unpack_one invalid package 4 size:%d, csize:%d", sz, 12 + node_sz + addr_sz);
		}
		lua_pushlstring(L, (const char *)buf + 8 + node_sz, addr_sz);			//addr
		lua_pushinteger(L, unpack_uint32(buf + 8 + node_sz + addr_sz));			//type

		char *msg = skynet_malloc(sz - 12 - node_sz - addr_sz);
		memcpy(msg, (const char *)buf + 12 + node_sz + addr_sz, sz - 12 - node_sz - addr_sz);
		lua_pushinteger(L, sz - 12 - node_sz - addr_sz);						//sz
		lua_pushlightuserdata(L, msg);											//msg
		return 7;
	}
}

static int
unpack_mult_f(lua_State *L, const uint8_t *buf, size_t sz) {
	// multinfo, session, node, addr, type, sz
	if (sz <= 7) {
		luaL_error(L, "unpack_mult_f invalid package 1 size:%d, csize:%d", sz, 7);
	}
	lua_pushinteger(L, (uint32_t)buf[0]);											//multinfo
	lua_pushinteger(L, unpack_uint32(buf + 1));										//session
	uint8_t node_sz = buf[5];
	if (node_sz <= 0) {
		luaL_error(L, "unpack_mult_f invalid node_sz:%d", node_sz);
	}
	if (sz <= 7 + node_sz) {		// 后面if else最低都是7
		luaL_error(L, "unpack_mult_f invalid package 2 size:%d, csize:%d", sz, 7 + node_sz);
	}
	lua_pushlstring(L, (const char *)buf + 6, node_sz);								//node
	uint8_t addr_type = buf[6 + node_sz];											//addr_type
	if (addr_type == 0) {
		if (sz < 19 + node_sz) {		// 信息可以空，所以<
			luaL_error(L, "unpack_mult_f invalid package 3 size:%d, csize:%d", sz, 19 + node_sz);
		}
		lua_pushinteger(L, unpack_uint32(buf + 7 + node_sz));						//addr
		lua_pushinteger(L, unpack_uint32(buf + 11 + node_sz));						//type
		lua_pushinteger(L, unpack_uint32(buf + 15 + node_sz));						//sz
		return 6;
	} else {
		uint8_t addr_sz = buf[7 + node_sz];		//可以没有，回应的时候是没有的
		if (sz < 16 + node_sz + addr_sz) {		// 信息可CL空〉所以6
			luaL_error(L, "unpack_murt_f invalid package 4 size:%d. csize:%d", sz, 16 + node_sz + addr_sz);
		}
		lua_pushlstring(L, (const char *)buf + 8 + node_sz, addr_sz);				//addr
		lua_pushinteger(L, unpack_uint32(buf + 8 + node_sz + addr_sz));				//type
		lua_pushinteger(L, unpack_uint32(buf + 12 + node_sz + addr_sz));			//sz
		return 6;
	}
}

static int
unpack_mult(lua_State *L, const uint8_t *buf, size_t sz) {
	// multinfo, session, node, msg
	lua_pushinteger(L, (uint32_t)buf[0]);											//multinfo
	lua_pushinteger(L, unpack_uint32(buf + 1));										//session
	uint8_t node_sz = buf[5];
	if (node_sz <= 0) {
		luaL_error(L, "unpack_niult invalid node_sz :%d", node_sz);
	}
	if (sz < 6 + node_sz) {		// msg 可能为空
		luaL_error(L, "unpack_mult_f invalid package 2 size:%d, csize:%d", sz, 7 + node_sz);
	}
	lua_pushlstring(L, (const char *)buf + 6, node_sz);								//node
	lua_pushlstring(L, (const char *)buf + 6 + node_sz, sz - 6 - node_sz);			//msg
	return 4;
}

static int
lunpack(lua_State *L) {
	size_t sz;
	const char *msg = luaL_checklstring(L, 1, &sz);
	if (sz <= 0) {
		luaL_error(L, "invalid package size:%d", sz);
	}
	switch (msg[0]) {
		case 0:
			return unpack_one(L, (const uint8_t *)msg, sz);
		case MULTI_F:
			return unpack_mult_f(L, (const uint8_t *)msg, sz);
		case MULTI_M:
		case MULTI_E:
			return unpack_mult(L, (const uint8_t *)msg, sz);
		default:
			return luaL_error(L, "invalid un package type %d", msg[0]);
	}
}

static int
lconcat(lua_State *L) {
	if (!lua_istable(L, 1)) {
		return luaL_error(L, "first param must be table");
	}
	uint32_t sz = luaL_checkinteger(L, 2);
	if (sz <= 0) {
		return luaL_error(L, "pack msg size must >= 0");
	}
	lua_pop(L, 1);
	char *buff = skynet_malloc(sz);

	int idx = 1;
	int offset = 0;
	while(lua_geti(L, 1, idx) == LUA_TSTRING) {
		size_t s;
		const char *str = lua_tolstring(L, -1, &s);
		if (s + offset > sz) {
			skynet_free(buff);
			return luaL_error(L, "concat larger than pack msg size");
		}
		memcpy(buff + offset, str, s);
		lua_pop(L, 1);
		offset += s;
		++idx;
	}
	if (offset != sz) {
		skynet_free(buff);
		return luaL_error(L, "concat size not same with pack msg size");
	}

	// buff/sz will send to other service, See clusterd.lua
	lua_pushlightuserdata(L, buff);
	lua_pushinteger(L, sz);
	return 2;
}

int
luaopen_dpcluster_core(lua_State *L) {
	// get_ip();

	luaL_Reg l[] = {
		{ "pack", lpack },
		{ "pack_nf", lpack_nf },
		{ "unpack", lunpack },
		{ "concat", lconcat },
		{ NULL, NULL },
	};
	luaL_checkversion(L);
	luaL_newlib(L, l);

	return 1;
}