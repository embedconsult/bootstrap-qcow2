#ifndef __HACK_PWM_H
#define __HACK_PWM_H

#include <sys/types.h>
#include <dirent.h>

#define getpwnam(x) NULL

struct passwd {
	char    *pw_name;	/* User's login name. */
	uid_t    pw_uid;	/* Numerical user ID. */
	gid_t    pw_gid;	/* Numerical group ID. */
	char    *pw_dir;	/* Initial working directory. */
	char    *pw_shell;	/* Program to use as shell. */
};

#endif

