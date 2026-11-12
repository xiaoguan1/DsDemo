CC = gcc
CFLAGS = -O2 -fPIC -Wall
LUADIR = ../../../../../skynet/3rd/lua/
SKYNETDIR = ../../../../../skynet/skynet-src/
INCLUDES = -I../.. -I$(LUADIR) -I$(SKYNETDIR)

TARGET = protobuf.so
SHARED = -shared

.PHONY : all clean

all : $(TARGET)

$(TARGET) : pbc-lua53.c
	$(CC) $(CFLAGS) $(SHARED) -o $@ $(INCLUDES) -L../../build $^ -lpbc

clean :
	rm -f $(TARGET)
