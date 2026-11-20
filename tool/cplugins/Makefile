CC ?= gcc
CPLUGINS_SO ?= ../cplugins-so
LUA_INC ?= ../../skynet/3rd/lua
SHARED := -fPIC --shared

CFLAGS = -g -O2 -Wall -I$(LUA_INC) $(MYCFLAGS)

$(CPLUGINS_SO)/dpcluster.so : dpcluster.c | $(CPLUGINS_SO)
	$(CC) $(CFLAGS) $(SHARED) -I/ $^ -o $@ 

$(CPLUGINS_SO)/posix.so : posix.c | $(CPLUGINS_SO)
	$(CC) $(CFLAGS) $(SHARED) -I/ $^ -o $@

$(CPLUGINS_SO)/util.so : util.c | $(CPLUGINS_SO)
	$(CC) $(CFLAGS) $(SHARED) -I/ $^ -o $@

$(CPLUGINS_SO)/crc.so : crc.c | $(CPLUGINS_SO)
	$(CC) $(CFLAGS) $(SHARED) -I/ $^ -o $@

CPLUGINS_ALL = dpcluster posix util crc
all : \
	$(foreach v, $(CPLUGINS_ALL), $(CPLUGINS_SO)/$(v).so) 