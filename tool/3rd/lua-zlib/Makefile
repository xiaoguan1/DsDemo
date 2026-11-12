CC = gcc
CFLAGS = -O3 -fPIC -Wall -DNDEBUG
# 开启 LZLIB_COMPAT 兼容模式（提供 zlib.compress / zlib.decompress 等）
# -Wno-unused-function: 兼容块中未注册到元表的 lzstream_* 方法会触发 unused 警告，屏蔽之
COMPAT_CFLAGS = $(CFLAGS) -DLZLIB_COMPAT -Wno-unused-function
LUADIR = ../../../skynet/3rd/lua/
TARGET = ../../cplugins-so/zlib.so

.PHONY : all compat clean

all : $(TARGET)

$(TARGET) : lua_zlib.c
	$(CC) $(CFLAGS) -shared -o $@ -I$(LUADIR) $^ -lz

# 编译携带 LZLIB_COMPAT 的版本: make compat
compat :
	$(CC) $(COMPAT_CFLAGS) -shared -o $(TARGET) -I$(LUADIR) lua_zlib.c -lz

clean :
	rm -f $(TARGET)