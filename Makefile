prefix = /usr/share

all:

install:
	install -m 0644 -D -t $(DESTDIR)$(prefix)/freeradius-oauth2-perl main.pm module policy 

