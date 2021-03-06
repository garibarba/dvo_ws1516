/**
 * \file
 * \brief   Set of functions used for the alignment part of the algorithm. Including:
 * 		   	* Warping
 * 		   	* Jacobian
 * 		   	* Residuals & error
 * 		   	* Weights
 * 		   	* Matrix multiplications (non-cuBLAS)
 *
 * \author  Oskar Carlbaum, Guillermo Gonzalez de Garibay, Georg Kuschk 04/2016
 */

#pragma once

#include <cuda_runtime.h>
#include <stdio.h>  // for a single warning

#define TDIST_DOF 5

//_____________________________________________
//_____________________________________________
//________CODE USED IN ALL CASES
//_____________________________________________
//_____________________________________________

/**
 * Image transformation function. Takes in the gray and depth values of the first
 * frame and calculates their positions and proyection in the second frame.
 * The transformation matrices RK_inv and K are not passed as arguments because
 * they are in constant memory.
 * @param x_prime  Output. Is the x coordinate of the 3D point in the second frame.
 * @param y_prime  Output. Is the y coordinate of the 3D point in the second frame.
 * @param z_prime  Output. Is the z coordinate of the 3D point in the second frame.
 * @param u_warped Output. Is the u coordinate of the point in the second camera frame. It is set to -1 for non valid points (bad depth value or out of bounds in the second camera frame).
 * @param v_warped Output. Is the v coordinate of the point in the second camera frame. It is set to -1 for non valid points (bad depth value or out of bounds in the second camera frame).
 * @param depthImg Input. Depth image in the first frame.
 * @param width    Current image height.
 * @param height   Current image height.
 * @param level    Current level in the pyramid.
 */
__global__ void d_transform_points( float *x_prime,
                                    float *y_prime,
                                    float *z_prime,
                                    float *u_warped,    //used as valid/non-valid mask too
                                    float *v_warped,    //used as valid/non-valid mask too
                                    const float *depthImg,
                                    const int width,
                                    const int height,
                                    const int level ) {
        // Get the 2D-coordinate of the pixel of the current thread
        const int   x = blockIdx.x * blockDim.x + threadIdx.x;
        const int   y = blockIdx.y * blockDim.y + threadIdx.y;
        const int pos = x + y * width;

        // If the 2D position is outside the image, do nothing
        if ( (x >= width) || (y >= height) )
                return;

        // if the depth value is not valid
        if ( (depthImg[pos] == 0) ) {
                u_warped[pos] = -1; // mark as not valid
                v_warped[pos] = -1; // mark as not valid
                return;
        }

        // get 3D point: p=(u*d, v*d, d) // u, v are the camera coordinates
        float p[3] = { x * depthImg[pos],
                       y * depthImg[pos],
                           depthImg[pos] };

        // unproject and transform: aux = RK_inv * p + t      // unproyect from camera: p = K_inv * p
                                                              // transform: p = R * p + t
        // matrices in constant memory are stored column-wise
        float aux[3];  // auxiliar variable
        for (int i = 0; i < 3; i++) {
                aux[i] = const_translation[i]
                         + p[0] * const_RK_inv[0 + i]
                         + p[1] * const_RK_inv[3 + i]
                         + p[2] * const_RK_inv[6 + i];
        }
        x_prime[pos] = aux[0];  y_prime[pos] = aux[1];  z_prime[pos] = aux[2];  // TODO: watch out if z_prime is 0. Looks unlikely...

        // proyect to camera: p = K * aux
        for (int i = 0; i < 3; i++) {
                p[i] =   aux[0] * const_K_pyr[0 + i + 9*level]
                       + aux[1] * const_K_pyr[3 + i + 9*level]
                       + aux[2] * const_K_pyr[6 + i + 9*level];
        }

        // get 2D camera coordinates in second frame: u2 = x/z; v2 = y/z
        // store (x',y') position for each (x,y)
        u_warped[pos] = p[0] / p[2];
        v_warped[pos] = p[1] / p[2];

        // if (x', y') is out of bounds in the second frame (not interpolable)
        if (    (u_warped[pos] < 0)
             || (u_warped[pos] > width-1)
             || (v_warped[pos] < 0)
             || (v_warped[pos] > height-1) )
        {
                u_warped[pos] = -1; // mark as not valid
                v_warped[pos] = -1; // mark as not valid
        }

        // const_K_pyr DEBUG
        // if (x == 0 && y == 0 && level == 0) {
        //     for (int i = 0; i < 9*MAX_LEVELS; i++)
        //         printf("%4.2f \n", const_K_pyr[i]);
        // }
}

/**
 * Calculates the jacobian matrix. Non valid pixels result in a whole row set to 0.
 * @param J        Output. Jacobian stored as a single array component-wise/column-wise (this is: the componets for each pixel are width*height positions apart).
 * @param x_prime  Input. Is the x coordinate of the 3D point in the second frame.
 * @param y_prime  Input. Is the y coordinate of the 3D point in the second frame.
 * @param z_prime  Input. Is the z coordinate of the 3D point in the second frame.
 * @param u_warped Input. Is the u coordinate of the point in the second camera frame. Used to get the interpolation coordinates for the derivatives. It is -1 for non valid points (bad depth value or out of bounds in the second camera frame).
 * @param v_warped Input. Is the v coordinate of the point in the second camera frame. Used to get the interpolation coordinates for the derivatives. It is -1 for non valid points (bad depth value or out of bounds in the second camera frame).
 * @param width    Current image height.
 * @param height   Current image height.
 * @param level    Current level in the pyramid.
 */
__global__ void d_calculate_jacobian( float *J,
                                    const float *x_prime,
                                    const float *y_prime,
                                    const float *z_prime,
                                    const float *u_warped,   // This is -1 for non-valid points
                                    const float *v_warped,   // This is -1 for non-valid points
                                    const int width,
                                    const int height,
                                    const int level ) {
        // Get the 2D-coordinate of the pixel of the current thread
        const int   x = blockIdx.x * blockDim.x + threadIdx.x;
        const int   y = blockIdx.y * blockDim.y + threadIdx.y;
        const int pos = x + y * width;

        // If the 2D position is outside the first image do nothing
        if ( (x >= width) || (y >= height) )
                return;
        // if the projection is outside the second frame gray values, set residual to 0
        if ( u_warped[pos] < 0 ) {
                for (int i = 0; i < 6; i++)
                    J[pos + i*width*height] = 0.0f;
                return;
        }

        // dxfx is the image gradient in x direction times the fx of the intrinsic camera calibration
        float dxfx, dyfy;   // factors common to all jacobian positions
        dxfx = tex2D( texRef_gray_dx, u_warped[pos], v_warped[pos] ) * const_K_pyr[0 + 9*level];
        dyfy = tex2D( texRef_gray_dy, u_warped[pos], v_warped[pos] ) * const_K_pyr[4 + 9*level];
        // // DEBUG
        // if (dxfx != dxfx)
        //              printf ("dxfx: pix %d intrp %f x %d y %d u %f v %f w %d h %d l %d \n", pos, tex2D( texRef_gray_dx, u_warped[pos], v_warped[pos] ), x, y, u_warped[pos], v_warped[pos], width, height, level );
        // if (dyfy != dyfy)
        //              printf ("dyfy: pix %d intrp %f x %d y %d u %f v %f w %d h %d l %d \n", pos, tex2D( texRef_gray_dy, u_warped[pos], v_warped[pos] ), x, y, u_warped[pos], v_warped[pos], width, height, level );
        // if (dxfx != dxfx)
        //              printf ("%d %f %d %d %f %f %d %d %d \n", pos, tex2D( texRef_gray_dx, u_warped[pos], v_warped[pos] ), x, y, u_warped[pos], v_warped[pos], width, height, level );
        // if (dyfy != dyfy)
        //              printf ("%d %f %d %d %f %f %d %d %d \n", pos, tex2D( texRef_gray_dy, u_warped[pos], v_warped[pos] ), x, y, u_warped[pos], v_warped[pos], width, height, level );

        float xp, yp, zp;   // for easyness of reading and debugging
        xp = x_prime[pos]; yp = y_prime[pos]; zp = z_prime[pos];

        if (zp == 0) printf("WARNING! DIVIDE BY zp ZERO in d_calculate_jacobian!!!"); // TODO

        J[pos + 0*width*height] = - dxfx / zp;
        J[pos + 1*width*height] = - dyfy / zp;
        J[pos + 2*width*height] = + ( dxfx*xp + dyfy*yp )
                                    / ( zp * zp );
        J[pos + 3*width*height] = + ( dxfx*xp*yp + dyfy*yp*yp )
                                    / ( zp * zp )
                                  + dyfy;
        J[pos + 4*width*height] = - ( dyfy*xp*yp + dxfx*xp*xp )
                                    / ( zp * zp )
                                  - dxfx;
        J[pos + 5*width*height] = + dxfx*yp / zp
                                  - dyfy*xp / zp;

        // // DEBUG // mostly big numbers??? // sometimes dxfx *or* dyfy are wrong. Not both.
        // for (int i = 0; i < 6; i++) {
        //     if ( J[pos + i*width*height] !=  J[pos + i*width*height])
        //             printf ("pix %d var %d val %f \n", pos, i, J[pos + i*width*height] );
        // }

}

/**
 * Calculates the residuals array. Non valid pixels get a 0 residual.
 * The gray image of the second frame is accessed through texture memory for interpolation.
 * @param r        Output. Array with all the residuals.
 * @param grayPrev Input. Gray image of the first frame.
 * @param u_warped Input. Is the u coordinate of the point in the second camera frame. Used to get the interpolation coordinates for the derivatives. It is -1 for non valid points (bad depth value or out of bounds in the second camera frame).
 * @param v_warped Input. Is the v coordinate of the point in the second camera frame. Used to get the interpolation coordinates for the derivatives. It is -1 for non valid points (bad depth value or out of bounds in the second camera frame).
 * @param width    Current image height.
 * @param height   Current image height.
 * @param level    Current level in the pyramid.
 */
__global__ void d_calculate_residuals( float *r,
                                    const float *grayPrev,
                                    const float *u_warped,   // This is -1 for non-valid points
                                    const float *v_warped,   // This is -1 for non-valid points
                                    const int width,
                                    const int height,
                                    const int level ) {
        // Get the 2D-coordinate of the pixel of the current thread
        const int   x = blockIdx.x * blockDim.x + threadIdx.x;
        const int   y = blockIdx.y * blockDim.y + threadIdx.y;
        const int pos = x + y * width;

        // If the 2D position is outside the first image do nothing
        if ( (x >= width) || (y >= height) )
                return;
        // if the projection is outside the second frame gray values, set residual to 0
        if ( u_warped[pos] < 0 ) {
                r[pos] = 0.0f;
                return;
        }

        r[pos] = grayPrev[pos] - tex2D( texRef_grayImg, u_warped[pos], v_warped[pos] );
}

//_____________________________________________
//_____________________________________________
//________CODE FOR CALCULATING WEIGHTS
//_____________________________________________
//_____________________________________________

/**
 * Set an array of size width*height to ones.
 * @param W      Output. Array of size width*height to fill with ones.
 * @param width    Current image height.
 * @param height   Current image height.
 */
__global__ void d_set_uniform_weights( float *W,
                                      const int width,
                                      const int height ) {
        // Get the 2D-coordinate of the pixel of the current thread
        const int   x = blockIdx.x * blockDim.x + threadIdx.x;
        const int   y = blockIdx.y * blockDim.y + threadIdx.y;
        const int pos = x + y * width;

        // If the 2D position is outside the first image or the projection outside the second, do nothing
        if ( (x >= width) || (y >= height) )
                return;

        W[pos] = 1.0f;
}

/**
 * Execute one step in the iteration to calculate the T-Distribution variance.
 * The number of degrees of freedom of the T-Distribution is set by the global
 * variable TDIST_DOF.
 * After this step a reduction is needed in order to sum up and average the values in aux.
 * @param aux       Output. Squared residuals multiplied by a factor. It is a step in the iteration to calculate a T-Distribution variance.
 * @param residuals Input. Residuals array.
 * @param width     Current level image width.
 * @param height    Current level image height.
 * @param variance  Input. T-Distribution variance in the previous iterative step.
 */
__global__ void d_calculate_tdist_variance(float *aux,
                                      const float *residuals,
                                      const int width,
                                      const int height,
                                      float variance) {
        int x = threadIdx.x + blockIdx.x * blockDim.x;
        int y = threadIdx.y + blockIdx.y * blockDim.y;

        if (x < width && y < height) {
                float r_data_squared = residuals[x + y*width] * residuals[x + y*width];
                //TDIST_DOF is degrees of freedom and is set to 5 as a compiler variable
                aux[x + y*width] = r_data_squared * ( (TDIST_DOF + 1.0f) / (TDIST_DOF + (r_data_squared) / (variance) ) );
        }
}

__global__ void d_calculate_tdist_weights( float *weights,
                                     const float *residuals,
                                     const int width,
                                     const int height,
                                     float variance) {
       int x = threadIdx.x + blockIdx.x * blockDim.x;
       int y = threadIdx.y + blockIdx.y * blockDim.y;

       if (x < width && y < height) {
               float r_data_squared = residuals[x + y*width] * residuals[x + y*width];
               //TDIST_DOF is degrees of freedom and is set to 5 at the very top
               weights[x + y*width] = ( (TDIST_DOF + 1.0f) / (TDIST_DOF + (r_data_squared) / (variance) ) );
       }
}

//_____________________________________________
//_____________________________________________
//________CODE FOR REDUCTIONS ON A LINEAR ARRAY
//_____________________________________________
//_____________________________________________

/**
 * First square every element, then reduce an array by a factor of blockDim.x .
 * This kernel is suposed to be called with a 1D grid and a 1D kernel.
 * @param input   Input array of size n.
 * @param results Output array of size ceil(n/blockIdx.x) .
 * @param n       Size of the input array.
 */
__global__ void d_squares_sum( const float *input,
                               float *results,
                               int n) {
        extern __shared__ float sdata[];
        int i = threadIdx.x + blockDim.x * blockIdx.x;
        int tx = threadIdx.x;
        // load input into __shared__ memory
        if (i < n) {
                sdata[tx] = input[i] * input[i];
                __syncthreads();
        } else {
                sdata[tx] = 0;
                __syncthreads();
        }
        if (i < n) {
                // block-wide reduction in __shared__ mem
                for(int offset = blockDim.x / 2; offset > 0; offset /= 2) {
                        if(tx < offset) {
                                // add a partial sum upstream to our own
                                sdata[tx] += sdata[tx + offset];
                        }
                        __syncthreads();
                }
                // finally, thread 0 writes the result
                if(threadIdx.x == 0) {
                        // note that the result is per-block
                        // not per-thread
                        results[blockIdx.x] = sdata[0];
                }
        }
}

/**
 * Reduce an array by a factor of blockDim.x .
 * This kernel is suposed to be called with a 1D grid and a 1D kernel.
 * @param input   Input array of size n.
 * @param results Output array of size ceil(n/blockIdx.x) .
 * @param n       Size of the input array.
 */
__global__ void d_sum(float *input, float *results, int n) {
        extern __shared__ float sdata[];
        int i = threadIdx.x + blockDim.x * blockIdx.x;
        int tx = threadIdx.x;
        // load input into __shared__ memory
        if (i < n) {
                sdata[tx] = input[i];
                __syncthreads();
        } else {
                sdata[tx] = 0;
                __syncthreads();
        }
        if (i < n) {
                // block-wide reduction in __shared__ mem
                for(int offset = blockDim.x / 2; offset > 0; offset /= 2) {
                        if(tx < offset) {
                                // add a partial sum upstream to our own
                                sdata[tx] += sdata[tx + offset];
                        }
                        __syncthreads();
                }
                // finally, thread 0 writes the result
                if(threadIdx.x == 0) {
                        // note that the result is per-block
                        // not per-thread
                        results[blockIdx.x] = sdata[0];
                }
        }
}

//_______________________________________________________
//_______________________________________________________
//________OTHER CODE
//_______________________________________________________
//_______________________________________________________

// Not used because it is not needed to know the mean error, but only the sum of
// the squared residuals, to use as a iteration stop criterium.
// /**
//  * Calculate the mean error. To be called with a gridSize and blockSize of 1.
//  * @param square_sum Input. Pointer to a float. Sum of the squared residuals.
//  * @param error      Output. Mean error.
//  * @param width      Width of current image.
//  * @param height     Height of current image.
//  */
// __global__ void d_get_error (  const float *square_sum,  // sum of the squares of the residuals
//                                float *error,
//                                const int width,
//                                const int height ) {
//         *error = *square_sum / (width*height);
// }

__global__ void d_calculate_jtw( float *JTW,
                                 const float *J,
                                 const float *W,
                                 const int width,
                                 const int height) {
         int x = threadIdx.x + blockIdx.x * blockDim.x;
         int y = threadIdx.y;
         int idx = x + y*width;
         if ( x < width ) {
                 JTW[idx] = J[idx] * W[x];
         }
 }

//_______________________________________________________
//_______________________________________________________
//________CODE REPLACING MATRIX MULTIPLICATIONS IN cuBLAS
//_______________________________________________________
//_______________________________________________________

/**
 * Returns a pre-computation of A=J'*W*J, just missing a reduce operation.
 * Each block calculates a sub-product of the whole, depending on its x, y, z
 * coordinates. z corresponds to how far along the long axis of the Jacobian the
 * sub-product of 1024 elements starts. x and y correspond to the row and column
 * of the resulting A matrix.
 * @param *pre_A        output for storing this pre-computation
 * @param *J            input Jacobian, component-wise stretched to 1D
 * @param *W            input weights matrix, corresponding to each pixel of the images
 * @param level_size    number of pixels in the image
 */
__global__ void d_product_JacT_W_Jac(   float *pre_A,
                                        const float *J,
                                        const float *W,
                                        const int level_size ) {
        extern __shared__ float sdata[];

        int rowJacT = blockIdx.x;   // row index for this thread of the transposed Jacobian, row index for A
        int colJac = blockIdx.y;    // column index for this thread of the Jacobian, colum index for y
        int subBlockIdx = blockIdx.z;   // how far along each [ column of the Jacobian ]/[ row of the transposed Jacobian ] the operation starts for the block
        int tx = threadIdx.x;
        int idxJacT = tx + subBlockIdx * blockDim.x + rowJacT * level_size ;  // thread index at the d_J array for the Jacobian transposed
        int idxJac  = tx + subBlockIdx * blockDim.x + colJac * level_size ;  // thread index at the d_J array for the Jacobian
        int idxW    = tx + subBlockIdx * blockDim.x;   // thread index for the Weights

        // load input into __shared__ memory
        if ( idxW < level_size ) {  // check if W is out of bounds and simultaneously check correct index of idxJac and idxJacT (these can wrap around rows)
                sdata[tx] = J[idxJacT] * W[idxW] * J[idxJac];   // J.T * W * J
                __syncthreads();
        } else {
                sdata[tx] = 0;
                __syncthreads();
        }
        if ( idxW < level_size ) {
                // block-wide reduction in __shared__ mem
                for(int offset = blockDim.x / 2; offset > 0; offset /= 2) {
                        if(tx < offset) {
                                // add a partial sum upstream to our own
                                sdata[tx] += sdata[tx + offset];
                        }
                        __syncthreads();
                }
                // finally, thread 0 writes the result
                if(threadIdx.x == 0) {
                        // note that the result is per-block
                        // not per-thread
                        pre_A[ subBlockIdx     // index along the dimension of pre_A to be later reduced to get A
                                + ( rowJacT + colJac * 6)     // index inside A, which will be stored column-wise
                                        * gridDim.z    // size of each array to be reduced to get each A element. They are stored head to tail column-wise along pre_A
                             ] = sdata[0];
                }
        }
}

/**
 * Reduces by a 1024 factor a matrix or an array from their pre-computed forms.
 * This is applied after d_product_JacT_W_Jac or d_product_JacT_W_res as many
 * times as needed to complete the matrix multiplication. The goal is to get M.
 * @param *M        output pre_M_reduced matrix, stored column-wise. If blockDim.z==1, the output will be the final result.
 * @param *pre_A    input to be reduced. It is the result of d_product_JacT_W_Jac or JacT_W_res.
 * @param *sizeZ    number of pre_A floats to be reduced to get each element of A. It is the Z component of the 3D matrix pre_A (stored as a linear array)
 */
__global__ void d_reduce_pre_M_towards_M(   float *pre_M_reduced,
                                            float *pre_M,
                                            int sizeZ ) {
        extern __shared__ float sdata[];
        // blockIdx.x is the row of M
        // blockIdx.y is the column of M

        // position along pre_M of thread pixel to load in memory
        int idx = threadIdx.x   // index along each 1024 array to reduce
                  + blockIdx.z * blockDim.z // starting position within each set of 1024 arrays
                  + (blockIdx.x + blockIdx.y * 6) * sizeZ;  // starting position of each set of 1024 arrays. Each set corresponds to a position in M
        int tx = threadIdx.x;
        // load input into __shared__ memory
        if (tx < sizeZ) {
                sdata[tx] = pre_M[idx];
                __syncthreads();
        } else {
                sdata[tx] = 0;
                __syncthreads();
        }
        if (tx < sizeZ) {
                // block-wide reduction in __shared__ mem
                for(int offset = blockDim.x / 2; offset > 0; offset /= 2) {
                        if(tx < offset) {
                                // add a partial sum upstream to our own
                                sdata[tx] += sdata[tx + offset];
                        }
                        __syncthreads();
                }
                // finally, thread 0 writes the result
                if(threadIdx.x == 0) {
                        // note that the result is per-block
                        // not per-thread
                        pre_M_reduced[ (blockIdx.x + blockIdx.y * 6)    // column-wise position in M
                                            * gridDim.z     // number of elements per M position
                                        + blockIdx.z    // element number for every M position
                                     ] = sdata[0];
                }
        }
}

/**
 * Returns a pre-computation of b=J'*W*r, just missing a reduce operation.
 * Each block calculates a sub-product of the whole, depending on its x, y, z
 * coordinates. z corresponds to how far along the long axis of the Jacobian the
 * sub-product of 1024 elements starts. x corresponds to the row of the resulting b array.
 *
 * This code is just a simplification of d_product_JacT_W_Jac, and thus is most likely
 * replaceable by it without any modification at all. They have just been kept separated
 * for the sake of understandability.
 * @param *pre_b        output for storing this pre-computation
 * @param *J            input Jacobian, component-wise stretched to 1D
 * @param *W            input weights matrix, corresponding to each pixel of the images
 * @param *res          input residual array
 * @param level_size    number of pixels in the image
 */
__global__ void d_product_JacT_W_res(   float *pre_b,
                                        const float *J,
                                        const float *W,
                                        const float *res,
                                        const int level_size ) {
        extern __shared__ float sdata[];

        int row = blockIdx.x;   // row index for this thread of the transposed Jacobian, row index for b
        int subBlockIdx = blockIdx.z;   // how far along each [ column of the Jacobian ]/[ row of the transposed Jacobian ] the operation starts for the block
        int tx = threadIdx.x;
        int idxJac = tx + subBlockIdx * blockDim.x + row * level_size ;  // thread index at the d_J array
        int idx    = tx + subBlockIdx * blockDim.x;   // thread index for the Weights and the residual

        // load input into __shared__ memory
        if ( idx < level_size ) {  // check if W is out of bounds and simultaneously check correct index of idxJac and idxJacT (these can wrap around rows)
                sdata[tx] = J[idxJac] * W[idx] * res[idx];   // J.T * W * res
                __syncthreads();
        } else {
                sdata[tx] = 0;
                __syncthreads();
        }
        if ( idx < level_size ) {
                // block-wide reduction in __shared__ mem
                for(int offset = blockDim.x / 2; offset > 0; offset /= 2) {
                        if(tx < offset) {
                                // add a partial sum upstream to our own
                                sdata[tx] += sdata[tx + offset];
                        }
                        __syncthreads();
                }
                // finally, thread 0 writes the result
                if(threadIdx.x == 0) {
                        // note that the result is per-block
                        // not per-thread
                        pre_b[ subBlockIdx     // index along the dimension of pre_b to be later reduced to get b
                                + row * gridDim.z    // row of b times the size of each array to be reduced to get each b element. These arrays are stored head to tail along pre_b
                             ] = sdata[0];
                }
        }
}

// // DEBUG
// __global__ void print_device_array( float *arr, const int width, const int height, const int level) {
//         // Get the 2D-coordinate of the pixel of the current thread
//         const int   x = blockIdx.x * blockDim.x + threadIdx.x;
//         const int   y = blockIdx.y * blockDim.y + threadIdx.y;
//         const int pos = x + y * width;
//
//         if ( (x >= width) || (y >= height))
//                 return;
//
//         if( arr[pos] != arr[pos] || true )
//             printf("lev %d val %f pos %d ", level, arr[pos], pos);
//         if( arr[pos] == INFINITY || arr[pos] == -INFINITY )
//             printf("inf: lev %d val %f pos %d ", level, arr[pos], pos);
//
// }
//
// __global__ void print_device_array_J( float *arr, const int width, const int height, const int level) {
//         // Get the 2D-coordinate of the pixel of the current thread
//         const int   x = blockIdx.x * blockDim.x + threadIdx.x;
//         const int   y = blockIdx.y * blockDim.y + threadIdx.y;
//         const int pos = x + y * width;
//
//         if ( (x >= width) || (y >= height))
//                 return;
//         int posJ;
//         for (int i=0; i < 6; i++) {
//             posJ = pos + i*width*height;
//             if( arr[posJ] != arr[posJ] )
//                 printf("lev %d val %f pos %d \n", level, arr[posJ], posJ);
//             if( arr[posJ] == INFINITY || arr[posJ] == -INFINITY )
//                 printf("inf: lev %d val %f pos %d \n", level, arr[posJ], posJ);
//         }
// }
