/*****************************************************************************
 * depth.c: bit-depth conversion video filter
 *****************************************************************************
 * Copyright (C) 2010-2011 x264 project
 *
 * Authors: Oskar Arvidsson <oskar@irock.se>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02111, USA.
 *
 * This program is also available under a commercial proprietary license.
 * For more information, contact us at licensing@x264.com.
 *****************************************************************************/

#include "video.h"
#define NAME "depth"
#define FAIL_IF_ERROR( cond, ... ) FAIL_IF_ERR( cond, NAME, __VA_ARGS__ )

cli_vid_filter_t depth_filter;

typedef struct
{
    hnd_t prev_hnd;
    cli_vid_filter_t prev_filter;

    int bit_depth;
    int dst_csp;
    int full_range;
    cli_pic_t buffer;
    int16_t *error_buf;
} depth_hnd_t;

static int depth_filter_csp_is_supported( int csp )
{
    int csp_mask = csp & X264_CSP_MASK;
    return csp_mask == X264_CSP_I420 ||
           csp_mask == X264_CSP_I422 ||
           csp_mask == X264_CSP_I444 ||
           csp_mask == X264_CSP_YV24 ||
           csp_mask == X264_CSP_YV12 ||
           csp_mask == X264_CSP_NV12;
}

static int csp_num_interleaved( int csp, int plane )
{
    int csp_mask = csp & X264_CSP_MASK;
    return ( csp_mask == X264_CSP_NV12 && plane == 1 ) ? 2 : 1;
}

/* The dithering algorithm is based on Sierra-2-4A error diffusion. It has been
 * written in such a way so that if the source has been upconverted using the
 * same algorithm as used in scale_image, dithering down to the source bit
 * depth again is lossless. */
#define DITHER_PLANE( pitch ) \
static void dither_plane_##pitch( pixel *dst, int dst_stride, uint16_t *src, int src_stride, \
                                        int width, int height, int16_t *errors, int full_range ) \
{ \
    int x, y; \
    const int lshift = 16-BIT_DEPTH; \
    const int rshift = 2*BIT_DEPTH-16; \
    const int pixel_max = (1 << BIT_DEPTH)-1; \
    const int half = 1 << (16-BIT_DEPTH); \
    memset( errors, 0, (width+1) * sizeof(int16_t) ); \
    for( y = 0; y < height; y++, src += src_stride, dst += dst_stride ) \
    { \
        int err = 0; \
        for( x = 0; x < width; x++ ) \
        { \
            err = err*2 + errors[x] + errors[x+1]; \
            dst[x*pitch] = x264_clip3( (((src[x*pitch]+half)<<2)+err)*pixel_max >> 18, 0, pixel_max ); \
            errors[x] = err = src[x*pitch] - (dst[x*pitch] << lshift) - (dst[x*pitch] >> rshift); \
            if( full_range ) \
               errors[x] = err = src[x*pitch] - (dst[x*pitch] << lshift) - (dst[x*pitch] >> rshift); \
            else \
               errors[x] = err = src[x*pitch] - (dst[x*pitch] << lshift); \
        } \
    } \
}

DITHER_PLANE( 1 )
DITHER_PLANE( 2 )

static void dither_image( cli_image_t *out, cli_image_t *img, int16_t *error_buf, int full_range )
{
    int i;
    int csp_mask = img->csp & X264_CSP_MASK;
    for( i = 0; i < img->planes; i++ )
    {
        int num_interleaved = csp_num_interleaved( img->csp, i );
        int height = x264_cli_csps[csp_mask].height[i] * img->height;
        int width = x264_cli_csps[csp_mask].width[i] * img->width / num_interleaved;

#define CALL_DITHER_PLANE( pitch, off ) \
        dither_plane_##pitch( ((pixel*)out->plane[i])+off, out->stride[i]/sizeof(pixel), \
                ((uint16_t*)img->plane[i])+off, img->stride[i]/2, width, height, error_buf, full_range )

        if( num_interleaved == 1 )
        {
            CALL_DITHER_PLANE( 1, 0 );
        }
        else
        {
            CALL_DITHER_PLANE( 2, 0 );
            CALL_DITHER_PLANE( 2, 1 );
        }
    }
}

static void scale_image( cli_image_t *output, cli_image_t *img, int full_range )
{
    int i;
    /* this function mimics how swscale does upconversion. 8-bit is converted
     * to 16-bit through left shifting the orginal value with 8 and then adding
     * the original value to that. This effectively keeps the full color range
     * while also being fast. for n-bit we basically do the same thing, but we
     * discard the lower 16-n bits. */
    int csp_mask = img->csp & X264_CSP_MASK;
     /* Decide the amount of shift needed by the type of color range */
    const int shift = full_range ? 16 - BIT_DEPTH : BIT_DEPTH - 8;
    for( i = 0; i < img->planes; i++ )
    {
        int j, k;
        uint8_t *src = img->plane[i];
        uint16_t *dst = (uint16_t*)output->plane[i];
        int height = x264_cli_csps[csp_mask].height[i] * img->height;
        int width = x264_cli_csps[csp_mask].width[i] * img->width;

        for( j = 0; j < height; j++ )
        {
            for( k = 0; k < width; k++ )
            {
                if( full_range )
                    /* x264's original algorithm */
                    dst[k] = ((src[k] << 8) + src[k]) >> shift;
                else
                    /* Limited range algorithm mentioned in BT.709 */
                    dst[k] = src[k] << shift;
             }

            src += img->stride[i];
            dst += output->stride[i]/2;
        }
    }
}

static int get_frame( hnd_t handle, cli_pic_t *output, int frame )
{
    depth_hnd_t *h = handle;

    if( h->prev_filter.get_frame( h->prev_hnd, output, frame ) )
        return -1;

    if( h->bit_depth < 16 && output->img.csp & X264_CSP_HIGH_DEPTH )
    {
        dither_image( &h->buffer.img, &output->img, h->error_buf, h->full_range );
        output->img = h->buffer.img;
    }
    else if( h->bit_depth > 8 && !(output->img.csp & X264_CSP_HIGH_DEPTH) )
    {
        scale_image( &h->buffer.img, &output->img, h->full_range );
        output->img = h->buffer.img;
    }
    return 0;
}

static int release_frame( hnd_t handle, cli_pic_t *pic, int frame )
{
    depth_hnd_t *h = handle;
    return h->prev_filter.release_frame( h->prev_hnd, pic, frame );
}

static void free_filter( hnd_t handle )
{
    depth_hnd_t *h = handle;
    h->prev_filter.free( h->prev_hnd );
    x264_cli_pic_clean( &h->buffer );
    x264_free( h );
}

static int init( hnd_t *handle, cli_vid_filter_t *filter, video_info_t *info,
                 x264_param_t *param, char *opt_string )
{
    if( info->csp & X264_CSP_SKIP_DEPTH_FILTER )
    {
        x264_cli_log( "depth", X264_LOG_INFO, "skipped depth filter\n" );
        info->csp = (info->csp & X264_CSP_MASK) | X264_CSP_HIGH_DEPTH;
        return 0;
    }

    int ret = 0;
    int change_fmt = (info->csp ^ param->i_csp) & X264_CSP_HIGH_DEPTH;
    int csp = ~(~info->csp ^ change_fmt);
    int bit_depth = 8*x264_cli_csp_depth_factor( csp );
    int full_range = info->full_range;
    if( full_range != 1 )
        full_range = 0;

    if( opt_string )
    {
        static const char *optlist[] = { "bit_depth", NULL };
        char **opts = x264_split_options( opt_string, optlist );

        if( opts )
        {
            char *str_bit_depth = x264_get_option( "bit_depth", opts );
            bit_depth = x264_otoi( str_bit_depth, -1 );

            ret = bit_depth < 8 || bit_depth > 16;
            csp = bit_depth > 8 ? csp | X264_CSP_HIGH_DEPTH : csp & ~X264_CSP_HIGH_DEPTH;
            change_fmt = (info->csp ^ csp) & X264_CSP_HIGH_DEPTH;
            x264_free_string_array( opts );
        }
        else
            ret = 1;
    }

    FAIL_IF_ERROR( bit_depth != BIT_DEPTH, "this build supports only bit depth %d\n", BIT_DEPTH )
    FAIL_IF_ERROR( ret, "unsupported bit depth conversion.\n" )

    /* only add the filter to the chain if it's needed */
    if( change_fmt || bit_depth != 8 * x264_cli_csp_depth_factor( csp ) )
    {
        depth_hnd_t *h;
        FAIL_IF_ERROR( !depth_filter_csp_is_supported(csp), "unsupported colorspace.\n" )
        h = x264_malloc( sizeof(depth_hnd_t) + (info->width+1)*sizeof(int16_t) );

        if( !h )
            return -1;

        h->error_buf = (int16_t*)(h + 1);
        h->dst_csp = csp;
        h->full_range = full_range;
        h->bit_depth = bit_depth;
        h->prev_hnd = *handle;
        h->prev_filter = *filter;

        if( x264_cli_pic_alloc( &h->buffer, h->dst_csp, info->width, info->height ) )
        {
            x264_free( h );
            return -1;
        }

        *handle = h;
        *filter = depth_filter;
        info->csp = h->dst_csp;
    }

    return 0;
}

cli_vid_filter_t depth_filter = { NAME, NULL, init, get_frame, release_frame, free_filter, NULL };
