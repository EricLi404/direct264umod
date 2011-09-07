# Makefile

include config.mak

all: default

SRCS = common/mc.c common/predict.c common/pixel.c common/macroblock.c \
       common/frame.c common/dct.c common/cpu.c common/cabac.c \
       common/common.c common/osdep.c common/rectangle.c \
       common/set.c common/quant.c common/deblock.c common/vlc.c \
       common/mvpred.c common/bitstream.c \
       encoder/analyse.c encoder/me.c encoder/ratecontrol.c \
       encoder/set.c encoder/macroblock.c encoder/cabac.c \
       encoder/cavlc.c encoder/encoder.c encoder/lookahead.c

SRCCLI = x264.c input/input.c input/timecode.c input/rawinput.c input/y4m.c \
         output/raw.c output/matroska.c output/matroska_ebml.c \
         output/flv.c output/flv_bytestream.c output/avi.c filters/filters.c \
         filters/video/video.c filters/video/source.c filters/video/internal.c \
         filters/video/resize.c filters/video/cache.c filters/video/fix_vfr_pts.c \
         filters/video/select_every.c filters/video/crop.c filters/video/depth.c \
         filters/video/hqdn3d.c filters/video/pad.c filters/video/vflip.c

SRCCLI += output/mp4.c
SRCCLI += $(addprefix output/mp4/, isom.c utils.c mp4sys.c mp4a.c summary.c importer.c)

SRCSO =

CONFIG := $(shell cat config.h)

# GPL-only files
ifneq ($(findstring HAVE_GPL 1, $(CONFIG)),)
SRCCLI += filters/video/yadif.c filters/video/yadif_filter_line.c

ifeq ($(ARCH),X86)
SRCCLI += filters/video/x86/yadif_filter_line.c
endif

endif

# Optional module sources
ifneq ($(findstring HAVE_AVS 1, $(CONFIG)),)
SRCCLI += input/avs.c input/dshow.c input/deldup.c filters/video/subtitle.c
endif

ifneq ($(findstring HAVE_THREAD 1, $(CONFIG)),)
SRCCLI += input/thread.c
SRCS   += common/threadpool.c
endif

ifneq ($(findstring HAVE_WIN32THREAD 1, $(CONFIG)),)
SRCS += common/win32thread.c
endif

ifneq ($(findstring HAVE_LAVF 1, $(CONFIG)),)
SRCCLI += input/lavf.c
endif

ifneq ($(findstring HAVE_FFMS 1, $(CONFIG)),)
SRCCLI += input/ffms.c
endif

# Visualization sources
ifneq ($(findstring HAVE_VISUALIZE 1, $(CONFIG)),)
SRCS   += common/visualize.c common/display-x11.c
endif

# MMX/SSE optims
ifneq ($(AS),)
X86SRC0 = const-a.asm cabac-a.asm dct-a.asm deblock-a.asm mc-a.asm \
          mc-a2.asm pixel-a.asm predict-a.asm quant-a.asm \
          cpu-a.asm dct-32.asm bitstream-a.asm
ifneq ($(findstring HIGH_BIT_DEPTH, $(CONFIG)),)
X86SRC0 += sad16-a.asm
else
X86SRC0 += sad-a.asm
endif
X86SRC = $(X86SRC0:%=common/x86/%)

ifeq ($(ARCH),X86)
ARCH_X86 = yes
ASMSRC   = $(X86SRC) common/x86/pixel-32.asm
endif

ifeq ($(ARCH),X86_64)
ARCH_X86 = yes
ASMSRC   = $(X86SRC:-32.asm=-64.asm)
ASFLAGS += -DARCH_X86_64
endif

ifdef ARCH_X86
ASFLAGS += -Icommon/x86/
SRCS   += common/x86/mc-c.c common/x86/predict-c.c
OBJASM  = $(ASMSRC:%.asm=%.o)
$(OBJASM): common/x86/x86inc.asm common/x86/x86util.asm
checkasm: tools/checkasm-a.o
endif
endif

# AltiVec optims
ifeq ($(ARCH),PPC)
ifneq ($(AS),)
SRCS += common/ppc/mc.c common/ppc/pixel.c common/ppc/dct.c \
        common/ppc/quant.c common/ppc/deblock.c \
        common/ppc/predict.c
endif
endif

# NEON optims
ifeq ($(ARCH),ARM)
ifneq ($(AS),)
ASMSRC += common/arm/cpu-a.S common/arm/pixel-a.S common/arm/mc-a.S \
          common/arm/dct-a.S common/arm/quant-a.S common/arm/deblock-a.S \
          common/arm/predict-a.S
SRCS   += common/arm/mc-c.c common/arm/predict-c.c
OBJASM  = $(ASMSRC:%.S=%.o)
endif
endif

# VIS optims
ifeq ($(ARCH),UltraSPARC)
ifeq ($(findstring HIGH_BIT_DEPTH, $(CONFIG)),)
ASMSRC += common/sparc/pixel.asm
OBJASM  = $(ASMSRC:%.asm=%.o)
endif
endif

ifneq ($(HAVE_GETOPT_LONG),1)
SRCCLI += extras/getopt.c
endif

ifneq ($(SONAME),)
ifeq ($(SYS),WINDOWS)
SRCSO += x264dll.c
endif
endif

OBJS = $(SRCS:%.c=%.o)
OBJCLI = $(SRCCLI:%.c=%.o)
OBJSO = $(SRCSO:%.c=%.o)
DEP  = depend

.PHONY: all default fprofiled generate use clean distclean install uninstall dox test testclean lib-static lib-shared cli install-lib-dev install-lib-static install-lib-shared install-cli

default: $(DEP)

cli: x264$(EXE)
lib-static: $(LIBX264)
lib-shared: $(SONAME)

$(LIBX264): .depend $(OBJS) $(OBJASM)
	$(AR)$@ $(OBJS) $(OBJASM)
	$(if $(RANLIB), $(RANLIB) $@)

$(SONAME): .depend $(OBJS) $(OBJASM) $(OBJSO)
	$(LD)$@ $(OBJS) $(OBJASM) $(OBJSO) $(SOFLAGS) $(LDFLAGS)

x264$(EXE): .depend $(OBJCLI) $(CLI_LIBX264)
	$(LD)$@ $(OBJCLI) $(CLI_LIBX264) $(LDFLAGSCLI) $(LDFLAGS)

checkasm: tools/checkasm.o $(LIBX264)
	$(LD)$@ $+ $(LDFLAGS)

%.o: %.asm
	$(AS) $(ASFLAGS) -o $@ $<
	-@ $(if $(STRIP), $(STRIP) -x $@) # delete local/anonymous symbols, so they don't show up in oprofile

%.o: %.S
	$(AS) $(ASFLAGS) -o $@ $<
	-@ $(if $(STRIP), $(STRIP) -x $@) # delete local/anonymous symbols, so they don't show up in oprofile

.depend: config.mak
	@rm -f .depend
	@$(foreach SRC, $(SRCS) $(SRCCLI) $(SRCSO), $(CC) $(CFLAGS) $(SRC) $(DEPMT) $(SRC:%.c=%.o) $(DEPMM) 1>> .depend;)

config.mak:
	./configure

depend: .depend
ifneq ($(wildcard .depend),)
include .depend
endif

SRC2 = $(SRCS) $(SRCCLI)
# These should cover most of the important codepaths
OPT0 = --crf 30 -b1 -m1 -r1 --me dia --no-cabac --direct temporal --tune ssim --ssim --no-weightb --weightp 0 --b-pyramid 0 --vf resize:640,360,,,,lanczos/pad:0,60,0,60
ifeq ($(MP4),yes)
OPT0 += -o tmpout.mp4
endif
OPT1 = --crf 16 -b2 -m3 -r3 -i1 --me hex --no-8x8dct --direct spatial --no-dct-decimate -t0 --rc-lookahead 0 --slice-max-mbs 50 --weightp 1 --b-pyramid 1 -I infinite --nr 100 --fade-compensate 0.5
OPT2 = --crf 26 -b4 -m5 -r2 --me umh --merange 64 --cqm jvt --tune psnr --psnr --no-mixed-refs --b-adapt 2 -o tmpout.avi --slice-max-size 1500 --weightp 1 --b-pyramid 1 --vf hqdn3d
OPT3 = --crf 18 --b-adapt 0 -b3 -m9 -r5 --me umh -t1 -A all --b-pyramid normal --direct auto --no-fast-pskip --no-mbtree --weightp 2 --fgo 10 --vf crop:16,16,16,16
OPT4 = --crf 22 -b3 -m7 -r4 --me esa -t2 -A all --psy-rd 1.0:1.0 --slices 4 --weightp 2 --vf select_every:2,0
OPT5 = --frames 100 --crf 24 -b3 -m10 -r3 --me umh -t2 -o tmpout.mkv --weightp 2 
OPT6 = --frames 100 -q0 -m9 -r2 --me hex -Aall --direct none
OPT7 = --frames 100 -q0 -m2 -r1 -t0 --me hex --no-cabac
OPT8 = --frames 50 -m11 --me tesa -t2 --aq-mode 3

ifeq (,$(VIDS))
fprofiled:
	@echo 'usage: make fprofiled VIDS="infile1 infile2 ..."'
	@echo 'where infiles are anything that x264 understands,'
	@echo 'i.e. YUV with resolution in the filename, y4m, or avisynth.'
else
fprofiled:
	$(MAKE) clean
	$(MAKE) x264$(EXE) CFLAGS="$(CFLAGS) $(PROF_GEN_CC)" LDFLAGS="$(LDFLAGS) $(PROF_GEN_LD)"
	$(foreach V, $(VIDS), $(foreach I, 0 1 2 3 4 5 6 7 8, ./x264$(EXE) $(OPT$I) --threads 1 $(V) -o $(DEVNULL) ;))
	rm -f $(SRC2:%.c=%.o)
	$(MAKE) CFLAGS="$(CFLAGS) $(PROF_USE_CC)" LDFLAGS="$(LDFLAGS) $(PROF_USE_LD)"
	rm -f $(SRC2:%.c=%.gcda) $(SRC2:%.c=%.gcno) *.dyn pgopti.dpi pgopti.dpi.lock
endif

generate:
	$(MAKE) clean
	$(MAKE) $(LIBX264) CFLAGS="$(CFLAGS) $(PROF_GEN_CC)" LDFLAGS="$(LDFLAGS) $(PROF_GEN_LD)"
	$(MAKE) x264$(EXE) CFLAGS="$(CFLAGS)" LDFLAGS="$(LDFLAGS) $(PROF_GEN_LD)"

use:
	rm -f $(SRC2:%.c=%.o)
	$(MAKE) $(LIBX264) CFLAGS="$(CFLAGS) $(PROF_USE_CC)" LDFLAGS="$(LDFLAGS) $(PROF_USE_LD)"
	$(MAKE) x264$(EXE) CFLAGS="$(CFLAGS)" LDFLAGS="$(LDFLAGS) $(PROF_USE_LD)"
	rm -f $(SRC2:%.c=%.gcda) $(SRC2:%.c=%.gcno) *.dyn pgopti.dpi pgopti.dpi.lock

clean:
	rm -f $(OBJS) $(OBJASM) $(OBJCLI) $(OBJSO) $(SONAME) *.a *.lib *.exp *.pdb x264 x264.exe .depend TAGS
	rm -f checkasm checkasm.exe tools/checkasm.o tools/checkasm-a.o
	rm -f $(SRC2:%.c=%.gcda) $(SRC2:%.c=%.gcno) *.dyn pgopti.dpi pgopti.dpi.lock

distclean: clean
	rm -f config.mak x264_config.h config.h config.log x264.pc x264.def
	rm -rf test/

install-cli: cli
	install -d $(DESTDIR)$(bindir)
	install x264$(EXE) $(DESTDIR)$(bindir)

install-lib-dev:
	install -d $(DESTDIR)$(includedir)
	install -d $(DESTDIR)$(libdir)
	install -d $(DESTDIR)$(libdir)/pkgconfig
	install -m 644 x264.h $(DESTDIR)$(includedir)
	install -m 644 x264_config.h $(DESTDIR)$(includedir)
	install -m 644 x264.pc $(DESTDIR)$(libdir)/pkgconfig

install-lib-static: lib-static install-lib-dev
	install -m 644 $(LIBX264) $(DESTDIR)$(libdir)
	$(if $(RANLIB), $(RANLIB) $(DESTDIR)$(libdir)/$(LIBX264))

install-lib-shared: lib-shared install-lib-dev
ifeq ($(SYS),WINDOWS)
	$(if $(SONAME), install -m 755 $(SONAME) $(DESTDIR)$(bindir))
else
	$(if $(SONAME), ln -f -s $(SONAME) $(DESTDIR)$(libdir)/libx264.$(SOSUFFIX))
	$(if $(SONAME), install -m 755 $(SONAME) $(DESTDIR)$(libdir))
endif
	$(if $(IMPLIBNAME), install -m 644 $(IMPLIBNAME) $(DESTDIR)$(libdir))

uninstall:
	rm -f $(DESTDIR)$(includedir)/x264.h $(DESTDIR)$(includedir)/x264_config.h $(DESTDIR)$(libdir)/libx264.a
	rm -f $(DESTDIR)$(bindir)/x264$(EXE) $(DESTDIR)$(libdir)/pkgconfig/x264.pc
	$(if $(SONAME), rm -f $(DESTDIR)$(libdir)/$(SONAME) $(DESTDIR)$(libdir)/libx264.$(SOSUFFIX))

etags: TAGS

TAGS:
	etags $(SRCS)
