/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file cocoa_v.mm Code related to the cocoa video driver(s). */

/******************************************************************************
 *                             Cocoa video driver                             *
 * Known things left to do:                                                   *
 *  Nothing at the moment.                                                    *
 ******************************************************************************/

#ifdef WITH_COCOA

#include "../../stdafx.h"
#include "../../os/macosx/macos.h"

#define Rect  OTTDRect
#define Point OTTDPoint
#import <Cocoa/Cocoa.h>
#undef Rect
#undef Point

#include "../../openttd.h"
#include "../../debug.h"
#include "../../rev.h"
#include "../../core/geometry_type.hpp"
#include "cocoa_v.h"
#include "cocoa_wnd.h"
#include "../../blitter/factory.hpp"
#include "../../gfx_func.h"
#include "../../window_func.h"
#include "../../window_gui.h"
#include "../../core/math_func.hpp"
#include "../../framerate_type.h"

#include <array>
#import <sys/param.h> /* for MAXPATHLEN */

/**
 * Important notice regarding all modifications!!!!!!!
 * There are certain limitations because the file is objective C++.
 * gdb has limitations.
 * C++ and objective C code can't be joined in all cases (classes stuff).
 * Read http://developer.apple.com/releasenotes/Cocoa/Objective-C++.html for more information.
 */

/* On some old versions of MAC OS this may not be defined.
 * Those versions generally only produce code for PPC. So it should be safe to
 * set this to 0. */
#ifndef kCGBitmapByteOrder32Host
#define kCGBitmapByteOrder32Host 0
#endif

bool _cocoa_video_started = false;
CocoaSubdriver *_cocoa_subdriver = NULL;


static bool ModeSorter(const OTTD_Point &p1, const OTTD_Point &p2)
{
	if (p1.x < p2.x) return true;
	if (p1.x > p2.x) return false;
	if (p1.y < p2.y) return true;
	if (p1.y > p2.y) return false;
	return false;
}

static void QZ_GetDisplayModeInfo(CFArrayRef modes, CFIndex i, int &bpp, uint16 &width, uint16 &height)
{
	CGDisplayModeRef mode = static_cast<CGDisplayModeRef>(const_cast<void *>(CFArrayGetValueAtIndex(modes, i)));

	width = (uint16)CGDisplayModeGetWidth(mode);
	height = (uint16)CGDisplayModeGetHeight(mode);

#if (MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_11)
	/* Extract bit depth from mode string. */
	CFAutoRelease<CFStringRef> pixEnc(CGDisplayModeCopyPixelEncoding(mode));
	if (CFStringCompare(pixEnc.get(), CFSTR(IO32BitDirectPixels), kCFCompareCaseInsensitive) == kCFCompareEqualTo) bpp = 32;
	if (CFStringCompare(pixEnc.get(), CFSTR(IO16BitDirectPixels), kCFCompareCaseInsensitive) == kCFCompareEqualTo) bpp = 16;
	if (CFStringCompare(pixEnc.get(), CFSTR(IO8BitIndexedPixels), kCFCompareCaseInsensitive) == kCFCompareEqualTo) bpp = 8;
#else
	/* CGDisplayModeCopyPixelEncoding is deprecated on OSX 10.11+, but there are no 8 bpp modes anyway... */
	bpp = 32;
#endif
}

uint QZ_ListModes(OTTD_Point *modes, uint max_modes, CGDirectDisplayID display_id, int device_depth)
{
	CFAutoRelease<CFArrayRef> mode_list(CGDisplayCopyAllDisplayModes(display_id, nullptr));
	CFIndex num_modes = CFArrayGetCount(mode_list.get());

	/* Build list of modes with the requested bpp */
	uint count = 0;
	for (CFIndex i = 0; i < num_modes && count < max_modes; i++) {
		int bpp;
		uint16 width, height;

		QZ_GetDisplayModeInfo(mode_list.get(), i, bpp, width, height);

		if (bpp != device_depth) continue;

		/* Check if mode is already in the list */
		bool hasMode = false;
		for (uint i = 0; i < count; i++) {
			if (modes[i].x == width &&  modes[i].y == height) {
				hasMode = true;
				break;
			}
		}

		if (hasMode) continue;

		/* Add mode to the list */
		modes[count].x = width;
		modes[count].y = height;
		count++;
	}

	/* Sort list smallest to largest */
	std::sort(modes, modes + count, ModeSorter);

	return count;
}

/**
 * Update the video modus.
 *
 * @pre _cocoa_subdriver != NULL
 */
static void QZ_UpdateVideoModes()
{
	assert(_cocoa_subdriver != NULL);

	OTTD_Point modes[32];
	uint count = _cocoa_subdriver->ListModes(modes, lengthof(modes));

	_resolutions.clear();
	for (uint i = 0; i < count; i++) {
		_resolutions.emplace_back(modes[i].x, modes[i].y);
	}
}

/**
 * Find a suitable cocoa subdriver.
 *
 * @param width Width of display area.
 * @param height Height of display area.
 * @param bpp Colour depth of display area.
 * @param fullscreen Whether a fullscreen mode is requested.
 * @param fallback Whether we look for a fallback driver.
 * @return Pointer to window subdriver.
 */
static CocoaSubdriver *QZ_CreateSubdriver(int width, int height, int bpp, bool fullscreen, bool fallback)
{
	CocoaSubdriver *ret = QZ_CreateWindowQuartzSubdriver(width, height, bpp);
	if (ret != nullptr && fullscreen) ret->ToggleFullscreen(fullscreen);

	if (ret != nullptr) return ret;
	if (!fallback) return nullptr;

	/* Try again in 640x480 windowed */
	DEBUG(driver, 0, "Setting video mode failed, falling back to 640x480 windowed mode.");
	ret = QZ_CreateWindowQuartzSubdriver(640, 480, bpp);
	if (ret != nullptr) return ret;

	return nullptr;
}


static FVideoDriver_Cocoa iFVideoDriver_Cocoa;

/**
 * Stop the cocoa video subdriver.
 */
void VideoDriver_Cocoa::Stop()
{
	if (!_cocoa_video_started) return;

	CocoaExitApplication();

	delete _cocoa_subdriver;
	_cocoa_subdriver = NULL;

	_cocoa_video_started = false;
}

/**
 * Initialize a cocoa video subdriver.
 */
const char *VideoDriver_Cocoa::Start(const StringList &parm)
{
	if (!MacOSVersionIsAtLeast(10, 7, 0)) return "The Cocoa video driver requires Mac OS X 10.7 or later.";

	if (_cocoa_video_started) return "Already started";
	_cocoa_video_started = true;

	/* Don't create a window or enter fullscreen if we're just going to show a dialog. */
	if (!CocoaSetupApplication()) return NULL;

	this->orig_res = _cur_resolution;
	int width  = _cur_resolution.width;
	int height = _cur_resolution.height;
	int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();

	if (bpp != 8 && bpp != 32) {
		Stop();
		return "The cocoa quartz subdriver only supports 8 and 32 bpp.";
	}

	_cocoa_subdriver = QZ_CreateSubdriver(width, height, bpp, _fullscreen, true);
	if (_cocoa_subdriver == NULL) {
		Stop();
		return "Could not create subdriver";
	}

	this->GameSizeChanged();
	QZ_UpdateVideoModes();

	return NULL;
}

/**
 * Set dirty a rectangle managed by a cocoa video subdriver.
 *
 * @param left Left x cooordinate of the dirty rectangle.
 * @param top Uppder y coordinate of the dirty rectangle.
 * @param width Width of the dirty rectangle.
 * @param height Height of the dirty rectangle.
 */
void VideoDriver_Cocoa::MakeDirty(int left, int top, int width, int height)
{
	assert(_cocoa_subdriver != NULL);

	_cocoa_subdriver->MakeDirty(left, top, width, height);
}

/**
 * Start the main programme loop when using a cocoa video driver.
 */
void VideoDriver_Cocoa::MainLoop()
{
	/* Restart game loop if it was already running (e.g. after bootstrapping),
	 * otherwise this call is a no-op. */
	[ [ NSNotificationCenter defaultCenter ] postNotificationName:OTTDMainLaunchGameEngine object:nil ];

	/* Start the main event loop. */
	[ NSApp run ];
}

/**
 * Change the resolution when using a cocoa video driver.
 *
 * @param w New window width.
 * @param h New window height.
 * @return Whether the video driver was successfully updated.
 */
bool VideoDriver_Cocoa::ChangeResolution(int w, int h)
{
	assert(_cocoa_subdriver != NULL);

	bool ret = _cocoa_subdriver->ChangeResolution(w, h, BlitterFactory::GetCurrentBlitter()->GetScreenDepth());

	this->GameSizeChanged();
	QZ_UpdateVideoModes();

	return ret;
}

/**
 * Toggle between windowed and full screen mode for cocoa display driver.
 *
 * @param full_screen Whether to switch to full screen or not.
 * @return Whether the mode switch was successful.
 */
bool VideoDriver_Cocoa::ToggleFullscreen(bool full_screen)
{
	assert(_cocoa_subdriver != NULL);

	return _cocoa_subdriver->ToggleFullscreen(full_screen);
}

/**
 * Callback invoked after the blitter was changed.
 *
 * @return True if no error.
 */
bool VideoDriver_Cocoa::AfterBlitterChange()
{
	return this->ChangeResolution(_screen.width, _screen.height);
}

/**
 * An edit box lost the input focus. Abort character compositing if necessary.
 */
void VideoDriver_Cocoa::EditBoxLostFocus()
{
	if (_cocoa_subdriver != NULL) [ [ _cocoa_subdriver->cocoaview inputContext ] discardMarkedText ];
	/* Clear any marked string from the current edit box. */
	HandleTextInput(NULL, true);
}

/**
 * Handle a change of the display area.
 */
void VideoDriver_Cocoa::GameSizeChanged()
{
	if (_cocoa_subdriver == nullptr) return;

	/* Tell the game that the resolution has changed */
	_screen.width = _cocoa_subdriver->GetWidth();
	_screen.height = _cocoa_subdriver->GetHeight();
	_screen.pitch = _cocoa_subdriver->GetWidth();
	_screen.dst_ptr = _cocoa_subdriver->GetPixelBuffer();

	/* Store old window size if we entered fullscreen mode. */
	bool fullscreen = _cocoa_subdriver->IsFullscreen();
	if (fullscreen && !_fullscreen) this->orig_res = _cur_resolution;
	_fullscreen = fullscreen;

	BlitterFactory::GetCurrentBlitter()->PostResize();

	::GameSizeChanged();
}

class WindowQuartzSubdriver;

/* Subclass of OTTD_CocoaView to fix Quartz rendering */
@interface OTTD_QuartzView : OTTD_CocoaView
- (void)setDriver:(WindowQuartzSubdriver*)drv;
- (void)drawRect:(NSRect)invalidRect;
@end

class WindowQuartzSubdriver : public CocoaSubdriver {
private:
	/**
	 * This function copies 8bpp pixels from the screen buffer in 32bpp windowed mode.
	 *
	 * @param left The x coord for the left edge of the box to blit.
	 * @param top The y coord for the top edge of the box to blit.
	 * @param right The x coord for the right edge of the box to blit.
	 * @param bottom The y coord for the bottom edge of the box to blit.
	 */
	void BlitIndexedToView32(int left, int top, int right, int bottom);

	virtual void GetDeviceInfo();
	virtual bool SetVideoMode(int width, int height, int bpp);

public:
	WindowQuartzSubdriver();
	virtual ~WindowQuartzSubdriver();

	virtual void Draw(bool force_update);
	virtual void MakeDirty(int left, int top, int width, int height);
	virtual void UpdatePalette(uint first_color, uint num_colors);

	virtual uint ListModes(OTTD_Point *modes, uint max_modes);

	virtual bool ChangeResolution(int w, int h, int bpp);

	virtual bool IsFullscreen();
	virtual bool ToggleFullscreen(bool fullscreen); /* Full screen mode on OSX 10.7 */

	virtual int GetWidth() { return window_width; }
	virtual int GetHeight() { return window_height; }
	virtual void *GetPixelBuffer() { return buffer_depth == 8 ? pixel_buffer : window_buffer; }

	/* Convert local coordinate to window server (CoreGraphics) coordinate */
	virtual CGPoint PrivateLocalToCG(NSPoint *p);

	virtual NSPoint GetMouseLocation(NSEvent *event);
	virtual bool MouseIsInsideView(NSPoint *pt);

	virtual bool IsActive() { return active; }

	bool WindowResized();
};


@implementation OTTD_QuartzView

- (void)setDriver:(WindowQuartzSubdriver*)drv
{
	driver = drv;
}
- (void)drawRect:(NSRect)invalidRect
{
	if (driver->cgcontext == NULL) return;

	CGContextRef viewContext = (CGContextRef)[ [ NSGraphicsContext currentContext ] graphicsPort ];
	CGContextSetShouldAntialias(viewContext, FALSE);
	CGContextSetInterpolationQuality(viewContext, kCGInterpolationNone);

	/* The obtained 'rect' is actually a union of all dirty rects, let's ask for an explicit list of rects instead */
	const NSRect *dirtyRects;
	NSInteger     dirtyRectCount;
	[ self getRectsBeingDrawn:&dirtyRects count:&dirtyRectCount ];

	/* We need an Image in order to do blitting, but as we don't touch the context between this call and drawing no copying will actually be done here */
	CGImageRef fullImage = CGBitmapContextCreateImage(driver->cgcontext);

	/* Calculate total area we are blitting */
	uint32 blitArea = 0;
	for (int n = 0; n < dirtyRectCount; n++) {
		blitArea += (uint32)(dirtyRects[n].size.width * dirtyRects[n].size.height);
	}

	/*
	 * This might be completely stupid, but in my extremely subjective opinion it feels faster
	 * The point is, if we're blitting less than 50% of the dirty rect union then it's still a good idea to blit each dirty
	 * rect separately but if we blit more than that, it's just cheaper to blit the entire union in one pass.
	 * Feel free to remove or find an even better value than 50% ... / blackis
	 */
	NSRect frameRect = [ self frame ];
	if (blitArea / (float)(invalidRect.size.width * invalidRect.size.height) > 0.5f) {
		NSRect rect = invalidRect;
		CGRect clipRect;
		CGRect blitRect;

		blitRect.origin.x = rect.origin.x;
		blitRect.origin.y = rect.origin.y;
		blitRect.size.width = rect.size.width;
		blitRect.size.height = rect.size.height;

		clipRect.origin.x = rect.origin.x;
		clipRect.origin.y = frameRect.size.height - rect.origin.y - rect.size.height;

		clipRect.size.width = rect.size.width;
		clipRect.size.height = rect.size.height;

		/* Blit dirty part of image */
		CGImageRef clippedImage = CGImageCreateWithImageInRect(fullImage, clipRect);
		CGContextDrawImage(viewContext, blitRect, clippedImage);
		CGImageRelease(clippedImage);
	} else {
		for (int n = 0; n < dirtyRectCount; n++) {
			NSRect rect = dirtyRects[n];
			CGRect clipRect;
			CGRect blitRect;

			blitRect.origin.x = rect.origin.x;
			blitRect.origin.y = rect.origin.y;
			blitRect.size.width = rect.size.width;
			blitRect.size.height = rect.size.height;

			clipRect.origin.x = rect.origin.x;
			clipRect.origin.y = frameRect.size.height - rect.origin.y - rect.size.height;

			clipRect.size.width = rect.size.width;
			clipRect.size.height = rect.size.height;

			/* Blit dirty part of image */
			CGImageRef clippedImage = CGImageCreateWithImageInRect(fullImage, clipRect);
			CGContextDrawImage(viewContext, blitRect, clippedImage);
			CGImageRelease(clippedImage);
		}
	}

	CGImageRelease(fullImage);
}

@end


void WindowQuartzSubdriver::GetDeviceInfo()
{
	/* Initialize the video settings; this data persists between mode switches
	 * and gather some information that is useful to know about the display */

	/* Use the new API when compiling for OSX 10.6 or later */
	CGDisplayModeRef cur_mode = CGDisplayCopyDisplayMode(kCGDirectMainDisplay);
	if (cur_mode == NULL) { return; }

	this->device_width = CGDisplayModeGetWidth(cur_mode);
	this->device_height = CGDisplayModeGetHeight(cur_mode);

	CGDisplayModeRelease(cur_mode);
}

bool WindowQuartzSubdriver::IsFullscreen()
{
	return this->window != nil && ([ this->window styleMask ] & NSWindowStyleMaskFullScreen) != 0;
}

/** Switch to full screen mode on OSX 10.7
 * @return Whether we switched to full screen
 */
bool WindowQuartzSubdriver::ToggleFullscreen(bool fullscreen)
{
	if (this->IsFullscreen() == fullscreen) return true;

	if ([ this->window respondsToSelector:@selector(toggleFullScreen:) ]) {
		[ this->window performSelector:@selector(toggleFullScreen:) withObject:this->window ];
		return true;
	}

	return false;
}

bool WindowQuartzSubdriver::SetVideoMode(int width, int height, int bpp)
{
	this->setup = true;
	this->GetDeviceInfo();

	if (width > this->device_width) width = this->device_width;
	if (height > this->device_height) height = this->device_height;

	NSRect contentRect = NSMakeRect(0, 0, width, height);

	/* Check if we should recreate the window */
	if (this->window == nil) {
		OTTD_CocoaWindowDelegate *delegate;

		/* Set the window style */
		unsigned int style = NSTitledWindowMask;
		style |= (NSMiniaturizableWindowMask | NSClosableWindowMask);
		style |= NSResizableWindowMask;

		/* Manually create a window, avoids having a nib file resource */
		this->window = [ [ OTTD_CocoaWindow alloc ]
							initWithContentRect:contentRect
							styleMask:style
							backing:NSBackingStoreBuffered
							defer:NO ];

		if (this->window == nil) {
			DEBUG(driver, 0, "Could not create the Cocoa window.");
			this->setup = false;
			return false;
		}

		/* Add built in full-screen support when available (OS X 10.7 and higher)
		 * This code actually compiles for 10.5 and later, but only makes sense in conjunction
		 * with the quartz fullscreen support as found only in 10.7 and later
		 */
		if ([ this->window respondsToSelector:@selector(toggleFullScreen:) ]) {
			NSWindowCollectionBehavior behavior = [ this->window collectionBehavior ];
			behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
			[ this->window setCollectionBehavior:behavior ];

			NSButton* fullscreenButton = [ this->window standardWindowButton:NSWindowFullScreenButton ];
			[ fullscreenButton setAction:@selector(toggleFullScreen:) ];
			[ fullscreenButton setTarget:this->window ];
		}

		[ this->window setDriver:this ];

		char caption[50];
		snprintf(caption, sizeof(caption), "OpenTTD %s", _openttd_revision);
		NSString *nsscaption = [ [ NSString alloc ] initWithUTF8String:caption ];
		[ this->window setTitle:nsscaption ];
		[ this->window setMiniwindowTitle:nsscaption ];
		[ nsscaption release ];

		[ this->window setContentMinSize:NSMakeSize(64.0f, 64.0f) ];

		[ this->window setAcceptsMouseMovedEvents:YES ];
		[ this->window setViewsNeedDisplay:NO ];

		delegate = [ [ OTTD_CocoaWindowDelegate alloc ] init ];
		[ delegate setDriver:this ];
		[ this->window setDelegate:[ delegate autorelease ] ];
	} else {
		/* We already have a window, just change its size */
		[ this->window setContentSize:contentRect.size ];

		/* Ensure frame height - title bar height >= view height */
		float content_height = [ this->window contentRectForFrameRect:[ this->window frame ] ].size.height;
		contentRect.size.height = Clamp(height, 0, (int)content_height);

		if (this->cocoaview != nil) {
			height = (int)contentRect.size.height;
			[ this->cocoaview setFrameSize:contentRect.size ];
		}
	}

	this->window_width = width;
	this->window_height = height;
	this->buffer_depth = bpp;

	[ (OTTD_CocoaWindow *)this->window center ];

	/* Only recreate the view if it doesn't already exist */
	if (this->cocoaview == nil) {
		this->cocoaview = [ [ OTTD_QuartzView alloc ] initWithFrame:contentRect ];
		if (this->cocoaview == nil) {
			DEBUG(driver, 0, "Could not create the Quartz view.");
			this->setup = false;
			return false;
		}

		[ this->cocoaview setDriver:this ];

		[ (NSView*)this->cocoaview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable ];
		[ this->window setContentView:cocoaview ];
		[ this->cocoaview release ];
		[ this->window makeKeyAndOrderFront:nil ];
	}

	[ this->window setColorSpace:[ NSColorSpace sRGBColorSpace ] ];
	this->color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	if (this->color_space == nullptr) this->color_space = CGColorSpaceCreateDeviceRGB();
	if (this->color_space == nullptr) error("Could not get a valid colour space for drawing.");

	bool ret = WindowResized();
	this->UpdatePalette(0, 256);

	this->setup = false;

	return ret;
}

void WindowQuartzSubdriver::BlitIndexedToView32(int left, int top, int right, int bottom)
{
	const uint32 *pal   = this->palette;
	const uint8  *src   = (uint8*)this->pixel_buffer;
	uint32       *dst   = (uint32*)this->window_buffer;
	uint          width = this->window_width;
	uint          pitch = this->window_width;

	for (int y = top; y < bottom; y++) {
		for (int x = left; x < right; x++) {
			dst[y * pitch + x] = pal[src[y * width + x]];
		}
	}
}


WindowQuartzSubdriver::WindowQuartzSubdriver()
{
	this->window_width  = 0;
	this->window_height = 0;
	this->buffer_depth  = 0;
	this->window_buffer  = NULL;
	this->pixel_buffer  = NULL;
	this->active        = false;
	this->setup         = false;

	this->window = nil;
	this->cocoaview = nil;

	this->cgcontext = NULL;

	this->num_dirty_rects = MAX_DIRTY_RECTS;
}

WindowQuartzSubdriver::~WindowQuartzSubdriver()
{
	/* Release window mode resources */
	if (this->window != nil) [ this->window close ];

	CGContextRelease(this->cgcontext);

	CGColorSpaceRelease(this->color_space);
	free(this->window_buffer);
	free(this->pixel_buffer);
}

void WindowQuartzSubdriver::Draw(bool force_update)
{
	PerformanceMeasurer framerate(PFE_VIDEO);

	/* Check if we need to do anything */
	if (this->num_dirty_rects == 0 || [ this->window isMiniaturized ]) return;

	if (this->num_dirty_rects >= MAX_DIRTY_RECTS) {
		this->num_dirty_rects = 1;
		this->dirty_rects[0].left = 0;
		this->dirty_rects[0].top = 0;
		this->dirty_rects[0].right = this->window_width;
		this->dirty_rects[0].bottom = this->window_height;
	}

	/* Build the region of dirty rectangles */
	for (int i = 0; i < this->num_dirty_rects; i++) {
		/* We only need to blit in indexed mode since in 32bpp mode the game draws directly to the image. */
		if (this->buffer_depth == 8) {
			BlitIndexedToView32(
				this->dirty_rects[i].left,
				this->dirty_rects[i].top,
				this->dirty_rects[i].right,
				this->dirty_rects[i].bottom
			);
		}

		NSRect dirtyrect;
		dirtyrect.origin.x = this->dirty_rects[i].left;
		dirtyrect.origin.y = this->window_height - this->dirty_rects[i].bottom;
		dirtyrect.size.width = this->dirty_rects[i].right - this->dirty_rects[i].left;
		dirtyrect.size.height = this->dirty_rects[i].bottom - this->dirty_rects[i].top;

		/* Normally drawRect will be automatically called by Mac OS X during next update cycle,
		 * and then blitting will occur. If force_update is true, it will be done right now. */
		[ this->cocoaview setNeedsDisplayInRect:dirtyrect ];
		if (force_update) [ this->cocoaview displayIfNeeded ];
	}

	this->num_dirty_rects = 0;
}

void WindowQuartzSubdriver::MakeDirty(int left, int top, int width, int height)
{
	if (this->num_dirty_rects < MAX_DIRTY_RECTS) {
		dirty_rects[this->num_dirty_rects].left = left;
		dirty_rects[this->num_dirty_rects].top = top;
		dirty_rects[this->num_dirty_rects].right = left + width;
		dirty_rects[this->num_dirty_rects].bottom = top + height;
	}
	this->num_dirty_rects++;
}

void WindowQuartzSubdriver::UpdatePalette(uint first_color, uint num_colors)
{
	if (this->buffer_depth != 8) return;

	for (uint i = first_color; i < first_color + num_colors; i++) {
		uint32 clr = 0xff000000;
		clr |= (uint32)_cur_palette.palette[i].r << 16;
		clr |= (uint32)_cur_palette.palette[i].g << 8;
		clr |= (uint32)_cur_palette.palette[i].b;
		this->palette[i] = clr;
	}

	this->num_dirty_rects = MAX_DIRTY_RECTS;
}

uint WindowQuartzSubdriver::ListModes(OTTD_Point *modes, uint max_modes)
{
	return QZ_ListModes(modes, max_modes, kCGDirectMainDisplay, this->buffer_depth);
}

bool WindowQuartzSubdriver::ChangeResolution(int w, int h, int bpp)
{
	int old_width  = this->window_width;
	int old_height = this->window_height;
	int old_bpp    = this->buffer_depth;

	if (this->SetVideoMode(w, h, bpp)) return true;
	if (old_width != 0 && old_height != 0) this->SetVideoMode(old_width, old_height, old_bpp);

	return false;
}

/* Convert local coordinate to window server (CoreGraphics) coordinate */
CGPoint WindowQuartzSubdriver::PrivateLocalToCG(NSPoint *p)
{

	p->y = this->window_height - p->y;
	*p = [ this->cocoaview convertPoint:*p toView:nil ];
	*p = [ this->window convertRectToScreen:NSMakeRect(p->x, p->y, 0, 0) ].origin;

	p->y = this->device_height - p->y;

	CGPoint cgp;
	cgp.x = p->x;
	cgp.y = p->y;

	return cgp;
}

NSPoint WindowQuartzSubdriver::GetMouseLocation(NSEvent *event)
{
	NSPoint pt;

	if ( [ event window ] == nil) {
		pt = [ this->cocoaview convertPoint:[ [ this->cocoaview window ] convertRectFromScreen:NSMakeRect([ event locationInWindow ].x, [ event locationInWindow ].y, 0, 0) ].origin fromView:nil ];
	} else {
		pt = [ event locationInWindow ];
	}

	pt.y = this->window_height - pt.y;

	return pt;
}

bool WindowQuartzSubdriver::MouseIsInsideView(NSPoint *pt)
{
	return [ cocoaview mouse:*pt inRect:[ this->cocoaview bounds ] ];
}

/** Clear buffer to opaque black. */
static void ClearWindowBuffer(uint32 *buffer, uint32 pitch, uint32 height)
{
	uint32 fill = Colour(0, 0, 0).data;
	for (uint32 y = 0; y < height; y++) {
		for (uint32 x = 0; x < pitch; x++) {
			buffer[y * pitch + x] = fill;
		}
	}
}

bool WindowQuartzSubdriver::WindowResized()
{
	if (this->window == nil || this->cocoaview == nil) return true;

	NSRect newframe = [ this->cocoaview frame ];

	this->window_width = (int)newframe.size.width;
	this->window_height = (int)newframe.size.height;

	/* Create Core Graphics Context */
	free(this->window_buffer);
	this->window_buffer = malloc(this->window_width * this->window_height * sizeof(uint32));
	/* Initialize with opaque black. */
	ClearWindowBuffer((uint32 *)this->window_buffer, this->window_width, this->window_height);

	CGContextRelease(this->cgcontext);
	this->cgcontext = CGBitmapContextCreate(
		this->window_buffer,       // data
		this->window_width,        // width
		this->window_height,       // height
		8,                         // bits per component
		this->window_width * 4,    // bytes per row
		this->color_space,         // color space
		kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host
	);

	assert(this->cgcontext != NULL);
	CGContextSetShouldAntialias(this->cgcontext, FALSE);
	CGContextSetAllowsAntialiasing(this->cgcontext, FALSE);
	CGContextSetInterpolationQuality(this->cgcontext, kCGInterpolationNone);

	if (this->buffer_depth == 8) {
		free(this->pixel_buffer);
		this->pixel_buffer = malloc(this->window_width * this->window_height);
		if (this->pixel_buffer == NULL) {
			DEBUG(driver, 0, "Failed to allocate pixel buffer");
			return false;
		}
	}

	static_cast<VideoDriver_Cocoa *>(VideoDriver::GetInstance())->GameSizeChanged();

	/* Redraw screen */
	this->num_dirty_rects = MAX_DIRTY_RECTS;

	return true;
}


CocoaSubdriver *QZ_CreateWindowQuartzSubdriver(int width, int height, int bpp)
{
	WindowQuartzSubdriver *ret = new WindowQuartzSubdriver();

	if (!ret->ChangeResolution(width, height, bpp)) {
		delete ret;
		return NULL;
	}

	return ret;
}

#endif /* WITH_COCOA */
