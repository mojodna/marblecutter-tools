# marblecutter-tools

Tools to process raster data; transcoding (to COG) and metadata generation.

## GeoTIFF Settings

* block size (internal tiling) is 512x512
* sources are kept in their original CRS
* 4-band, 8-bit sources are assumed to be RGBA; band 4 (if present) is assumed to be an alpha channel and is extracted as the mask. RGB bands are converted to the YCbCr colorspace and JPEG-compressed w/ default quality settings. Pixel interleaving is used.
* floating-point sources are compressed using DEFLATE with a floating point predictor (3 for GDAL)
* all other sources are compressed using DEFLATE with a horizontal predictor (2 for GDAL)
* internal overviews are generated with the same settings and produced for factors of 2 until the overview is smaller than the block size (readers shouldn't gain much benefit beyond that even when rendering at very low resolutions)

BigTIFFs should be generated when necessary; since compression is in play, `BIGTIFF=IF_SAFER` is used (we added this recently after encountering a source within the threshold that GDAL's default heuristic didn't pick BigTIFF).

## External Masks

External masks (.msk sidecar) are currently created; this isn't ideal, but there were a couple driving reasons for doing this in the past (which may no longer be accurate, particularly after some recent improvements to rasterio):

* when read as masks by rasterio, [mask] overviews weren't used
* masks should be resampled using nearest-neighbor to preserve edge crispness, even when other resampling methods (lanczos, bicubic, etc) are used for imagery bands
