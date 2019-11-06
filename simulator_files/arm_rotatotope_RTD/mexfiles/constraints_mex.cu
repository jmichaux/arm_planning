/*
Author: Bohao Zhang
Oct. 30 2019

arm_planning mex

This code aims to generate constraint for rotatotopes
*/

#include "mex.h"
#include "rotatotopeArray.h"

__global__ void buff_obstacles_kernel(double* RZ, bool* c_idx, bool* k_idx, double* OZ, uint32_t OZ_unit_length, double* buff_obstacles, double* frs_k_dep_G, bool* k_con, uint8_t* k_con_num);

__global__ void polytope(double* buff_obstacles, double* frs_k_dep_G, uint8_t* k_con_num, uint32_t A_con_width, double* A_con, double* b_con);

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
	std::clock_t start_t, end_t; // timing
	/*
P0.	process the input
	*/
	if (nrhs != 7) {
		mexErrMsgIdAndTxt("MyProg:ConvertString", "Incorrect number of input!");
	}

	uint32_t n_links = (uint32_t)(*mxGetPr(prhs[0]));
	uint32_t n_joints = 2 * n_links;
	uint32_t n_time_steps = (uint32_t)(*mxGetPr(prhs[1]));

	double* RZ = mxGetPr(prhs[2]);
	uint32_t RZ_width = (uint32_t)mxGetM(prhs[2]);
	uint32_t RZ_length = (uint32_t)mxGetN(prhs[2]);

	double* dev_RZ;
	cudaMalloc((void**)&dev_RZ, RZ_length * RZ_width * sizeof(double));
	cudaMemcpy(dev_RZ, RZ, RZ_length * RZ_width * sizeof(double), cudaMemcpyHostToDevice);

	bool* c_idx = mxGetLogicals(prhs[3]);
	uint32_t c_idx_width = (uint32_t)mxGetM(prhs[3]);
	uint32_t c_idx_length = (uint32_t)mxGetN(prhs[3]);

	bool *dev_c_idx;
	cudaMalloc((void**)&dev_c_idx, c_idx_length * c_idx_width * sizeof(bool));
	cudaMemcpy(dev_c_idx, c_idx, c_idx_length * c_idx_width * sizeof(bool), cudaMemcpyHostToDevice);

	bool* k_idx = mxGetLogicals(prhs[4]);
	uint32_t k_idx_width = (uint32_t)mxGetM(prhs[4]);
	uint32_t k_idx_length = (uint32_t)mxGetN(prhs[4]);

	bool *dev_k_idx;
	cudaMalloc((void**)&dev_k_idx, k_idx_length * k_idx_width * sizeof(bool));
	cudaMemcpy(dev_k_idx, k_idx, k_idx_length * k_idx_width * sizeof(bool), cudaMemcpyHostToDevice);

	uint32_t n_obstacles = (uint32_t)(*mxGetPr(prhs[5]));

	double* OZ = mxGetPr(prhs[6]);
	uint32_t OZ_width = (uint32_t)mxGetM(prhs[6]);
	uint32_t OZ_length = (uint32_t)mxGetN(prhs[6]);

	uint32_t OZ_unit_length = OZ_length / n_obstacles;

	double* dev_OZ;
	cudaMalloc((void**)&dev_OZ, OZ_length * OZ_width * sizeof(double));
	cudaMemcpy(dev_OZ, OZ, OZ_length * OZ_width * sizeof(double), cudaMemcpyHostToDevice);

	/*
P1.	buffer the obstacle by k-independent generators
	*/
	bool *k_con, *dev_k_con;
	uint8_t *k_con_num, *dev_k_con_num; // size of each k con
	k_con = new bool[n_links * (n_links + 1) * n_time_steps * reduce_order];
	cudaMalloc((void**)&dev_k_con, n_links * (n_links + 1) * n_time_steps * reduce_order * sizeof(bool));
	k_con_num = new uint8_t[n_links * n_time_steps];
	cudaMalloc((void**)&dev_k_con_num, n_links * n_time_steps * sizeof(uint8_t));

	double* dev_buff_obstacles;
	cudaMalloc((void**)&dev_buff_obstacles, n_obstacles * n_links * n_time_steps * max_buff_obstacle_size * 3 * sizeof(double));
	cudaMemset(dev_buff_obstacles, 0, n_obstacles * n_links * n_time_steps * max_buff_obstacle_size * 3 * sizeof(double));

	double* dev_frs_k_dep_G;
	cudaMalloc((void**)&dev_frs_k_dep_G, n_links * n_time_steps * reduce_order * 3 * sizeof(double));
	cudaMemset(dev_frs_k_dep_G, 0, n_links * n_time_steps * reduce_order * 3 * sizeof(double));

	dim3 grid1(n_obstacles, n_links, n_time_steps);
	buff_obstacles_kernel << < grid1, reduce_order >> > (dev_RZ, dev_c_idx, dev_k_idx, dev_OZ, OZ_unit_length, dev_buff_obstacles, dev_frs_k_dep_G, dev_k_con, dev_k_con_num);

	cudaMemcpy(k_con, dev_k_con, n_links * (n_links + 1) * n_time_steps * reduce_order * sizeof(bool), cudaMemcpyDeviceToHost);
	cudaMemcpy(k_con_num, dev_k_con_num, n_links * n_time_steps * sizeof(uint8_t), cudaMemcpyDeviceToHost);

	// find the maximum width of A_con for memory allocation
	uint32_t max_k_con_num = 0;
	for (uint32_t i = 0; i < n_links * n_time_steps; i++) {
		if (k_con_num[i] > max_k_con_num) {
			max_k_con_num = k_con_num[i];
		}
	}

	/*
P2.	generate obstacles polynomials
	*/
	double *A_con, *dev_A_con;
	A_con = new double[n_obstacles * n_links * n_time_steps * max_constraint_size * 2 * max_k_con_num];
	cudaMalloc((void**)&dev_A_con, n_obstacles * n_links * n_time_steps * max_constraint_size * 2 * max_k_con_num * sizeof(double));

	double *b_con, *dev_b_con;
	b_con = new double[n_obstacles * n_links * n_time_steps * max_constraint_size * 2];
	cudaMalloc((void**)&dev_b_con, n_obstacles * n_links * n_time_steps * max_constraint_size * 2 * sizeof(double));

	dim3 grid2(n_obstacles, n_links, n_time_steps);
	polytope << < grid2, max_constraint_size >> > (dev_buff_obstacles, dev_frs_k_dep_G, dev_k_con_num, max_k_con_num, dev_A_con, dev_b_con);

	cudaMemcpy(A_con, dev_A_con, n_obstacles * n_links * n_time_steps * max_constraint_size * 2 * max_k_con_num * sizeof(double), cudaMemcpyDeviceToHost);
	cudaMemcpy(b_con, dev_b_con, n_obstacles * n_links * n_time_steps * max_constraint_size * 2 * sizeof(double), cudaMemcpyDeviceToHost);

	/*
P3. handle the output, release the memory
	*/
	nlhs = 4;
	plhs[0] = mxCreateNumericMatrix(n_obstacles * n_links * max_constraint_size * 2, n_time_steps * max_k_con_num, mxDOUBLE_CLASS, mxREAL);
	double *output1 = mxGetPr(plhs[0]);
	for (uint32_t j = 0; j < n_time_steps; j++) {
		for (uint32_t k = 0; k < max_k_con_num; k++) {
			for (uint32_t i = 0; i < n_obstacles * n_links; i++){
				for (uint32_t p = 0; p < max_constraint_size * 2; p++) {
					output1[((j * max_k_con_num + k) * n_obstacles * n_links + i) * max_constraint_size * 2 + p] = A_con[((i * n_time_steps + j) * max_constraint_size * 2 + p) * max_k_con_num + k];
				}
			}
		}
	}

	plhs[1] = mxCreateNumericMatrix(n_obstacles * n_links * max_constraint_size * 2, n_time_steps, mxDOUBLE_CLASS, mxREAL);
	double *output2 = mxGetPr(plhs[1]);
	for (uint32_t j = 0; j < n_time_steps; j++) {
		for (uint32_t i = 0; i < n_obstacles * n_links; i++) {
			for (uint32_t p = 0; p < max_constraint_size * 2; p++) {
				output2[(j * n_obstacles * n_links + i) * max_constraint_size * 2 + p] = b_con[(i * n_time_steps + j) * max_constraint_size * 2 + p];
			}
		}
	}

	plhs[2] = mxCreateLogicalMatrix(n_links * (n_links + 1) * n_time_steps, reduce_order);
	bool *output3 = mxGetLogicals(plhs[2]);
	for (uint32_t i = 0; i < n_links * (n_links + 1) * n_time_steps; i++) {
		for (uint32_t j = 0; j < reduce_order; j++) {
			output3[j * n_links * (n_links + 1) * n_time_steps + i] = k_con[i * reduce_order + j];
		}
	}

	plhs[3] = mxCreateNumericMatrix(n_links, n_time_steps, mxDOUBLE_CLASS, mxREAL);
	double *output4 = mxGetPr(plhs[3]);
	for (uint32_t i = 0; i < n_links; i++) {
		for (uint32_t j = 0; j < n_time_steps; j++) {
			output4[j * n_links + i] = k_con_num[i * n_time_steps + j];
		}
	}
	
	cudaFree(dev_RZ);
	cudaFree(dev_c_idx);
	cudaFree(dev_k_idx);
	cudaFree(dev_OZ);
	delete[] k_con;
	cudaFree(dev_k_con);
	delete[] k_con_num;
	cudaFree(dev_k_con_num);
	cudaFree(dev_buff_obstacles);
	cudaFree(dev_frs_k_dep_G);
	delete[] A_con;
	cudaFree(dev_A_con);
	delete[] b_con;
	cudaFree(dev_b_con);
}

/*
Instruction:
	buffer the obstacle by k-independent generators
Requires:
	1. RZ
	2. c_idx
	3. k_idx
	4. OZ
	5. OZ_unit_length
Modifies:
	1. buff_obstacles
	2. frs_k_dep_G
	3. k_con
	4. k_con_num
*/
__global__ void buff_obstacles_kernel(double* RZ, bool* c_idx, bool* k_idx, double* OZ, uint32_t OZ_unit_length, double* buff_obstacles, double* frs_k_dep_G, bool* k_con, uint8_t* k_con_num) {
	uint32_t obstacle_id = blockIdx.x;
	uint32_t obstacle_base = obstacle_id * OZ_unit_length;
	uint32_t link_id = blockIdx.y;
	uint32_t n_links = gridDim.y;
	uint32_t time_id = blockIdx.z;
	uint32_t n_time_steps = gridDim.z;
	uint32_t z_id = threadIdx.x;
	uint32_t c_base = (link_id * n_time_steps + time_id) * reduce_order;
	uint32_t RZ_base = (link_id * n_time_steps + time_id) * 3 * reduce_order;
	uint32_t k_start = ((link_id * (link_id + 1)) * n_time_steps + time_id) * reduce_order;
	uint32_t k_end = (((link_id + 1) * (link_id + 2)) * n_time_steps + time_id) * reduce_order;
	uint32_t k_step = n_time_steps * reduce_order;
	uint32_t k_con_num_base = link_id * n_time_steps + time_id;
	uint32_t buff_base = ((obstacle_id * n_links + link_id) * n_time_steps + time_id) * max_buff_obstacle_size;
	
	// first, find kc_col
	__shared__ bool kc_info[reduce_order];

	kc_info[z_id] = false;
	for (uint32_t i = k_start; i < k_end; i += k_step) {
		if (k_idx[i + z_id] == true) {
			kc_info[z_id] = true;
			break;
		}
	}

	kc_info[z_id] &= c_idx[c_base + z_id];

	__syncthreads();

	if (z_id == 0) { // process the original obstacle zonotope
		for (uint32_t i = 0; i < 3; i++) {
			buff_obstacles[buff_base * 3 + i] = OZ[obstacle_base * 3 + i] - RZ[RZ_base + i * reduce_order];
		}

		for (uint32_t obs_g = 1; obs_g < OZ_unit_length; obs_g++) {
			for (uint32_t i = 0; i < 3; i++) {
				buff_obstacles[(buff_base + obs_g) * 3 + i] = OZ[(obstacle_base + obs_g) * 3 + i];
			}
		}
	}
	else if (z_id == 1) { // find k-dependent generators and complete k_con
		if (obstacle_id == 0) {
			uint8_t k_dep_num = 0;
			for (uint32_t z = 1; z < reduce_order; z++) {
				if (kc_info[z]) {
					for (uint32_t j = k_start; j < k_end; j += k_step) {
						k_con[j + k_dep_num] = k_idx[j + z];
					}

					for (uint32_t i = 0; i < 3; i++) {
						frs_k_dep_G[(c_base + k_dep_num) * 3 + i] = RZ[RZ_base + i * reduce_order + z];
					}

					k_dep_num++;
				}
			}

			k_con_num[k_con_num_base] = k_dep_num;
		}
	}
	else if (z_id == 2) { // find k-independent generators and complete buff_obstacles
		uint8_t k_indep_num = OZ_unit_length;
		for (uint32_t z = 1; z < reduce_order; z++) {
			if (!kc_info[z]) {
				for (uint32_t i = 0; i < 3; i++) {
					buff_obstacles[(buff_base + k_indep_num) * 3 + i] = RZ[RZ_base + i * reduce_order + z];
				}
				k_indep_num++;
			}
		}
	}
}

/*
Instruction:
	generate the polytopes of constraints
Requires:
	1. buff_obstacles
	2. frs_k_dep_G
	3. k_con_num
	4. A_con_width = max_k_con_num
Modifies:
	1. A_con
	2. b_con
*/
__global__ void polytope(double* buff_obstacles, double* frs_k_dep_G, uint8_t* k_con_num, uint32_t A_con_width, double* A_con, double* b_con) {
	uint32_t obstacle_id = blockIdx.x;
	uint32_t link_id = blockIdx.y;
	uint32_t n_links = gridDim.y;
	uint32_t time_id = blockIdx.z;
	uint32_t n_time_steps = gridDim.z;
	uint32_t k_con_base = link_id * n_time_steps + time_id;
	uint32_t k_dep_G_base = k_con_base * reduce_order;
	uint32_t obs_base = ((obstacle_id * n_links + link_id) * n_time_steps + time_id) * max_buff_obstacle_size;
	uint32_t c_id = threadIdx.x;
	uint32_t first = (uint32_t)floor(38.5 - 0.5 * sqrt(5929.0 - 8.0 * ((double)c_id)));
	uint32_t first_base = (obs_base + first + 1) * 3;
	uint32_t second = c_id + 1 - ((75 - first) * first) / 2;
	uint32_t second_base = (obs_base + second + 1) * 3;
	uint32_t con_base = ((obstacle_id * n_links + link_id) * n_time_steps + time_id) * max_constraint_size * 2 + c_id;
	
	double A_1 = buff_obstacles[first_base + 1] * buff_obstacles[second_base + 2] - buff_obstacles[first_base + 2] * buff_obstacles[second_base + 1];
	double A_2 = buff_obstacles[first_base + 2] * buff_obstacles[second_base]     - buff_obstacles[first_base]     * buff_obstacles[second_base + 2];
	double A_3 = buff_obstacles[first_base] *     buff_obstacles[second_base + 1] - buff_obstacles[first_base + 1] * buff_obstacles[second_base];
	double A_s_q = sqrt(A_1 * A_1 + A_2 * A_2 + A_3 * A_3);

	if (A_s_q != 0) {
		A_1 /= A_s_q;
		A_2 /= A_s_q;
		A_3 /= A_s_q;
	}
	else {
		A_1 = A_2 = A_3 = 0;
	}

	for (uint32_t i = 0; i < k_con_num[k_con_base]; i++) {
		A_con[con_base * A_con_width + i] = A_1 * frs_k_dep_G[(k_dep_G_base + i) * 3] + A_2 * frs_k_dep_G[(k_dep_G_base + i) * 3 + 1] + A_3 * frs_k_dep_G[(k_dep_G_base + i) * 3 + 2];
		A_con[(con_base + max_constraint_size) * A_con_width + i] = -A_con[con_base * A_con_width + i];
	}

	double d = A_1 * buff_obstacles[obs_base * 3] + A_2 * buff_obstacles[obs_base * 3 + 1] + A_3 * buff_obstacles[obs_base * 3 + 2];
	
	double deltaD = 0;
	for (uint32_t i = 1; i < max_buff_obstacle_size; i++) {
		deltaD += abs(A_1 * buff_obstacles[(obs_base + i) * 3] + A_2 * buff_obstacles[(obs_base + i) * 3 + 1] + A_3 * buff_obstacles[(obs_base + i) * 3 + 2]);
	}

	b_con[con_base] = d + deltaD;
	b_con[con_base + max_constraint_size] = -d + deltaD;
}