#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdbool.h>
#include <math.h>
#include "src/micro_molecule.h"
#include "src/rand_accord.h"

#define NUM_STEPS 100

// --- 1. Traditional Linked List (AoS) ---
struct bench_node3D {
    double x, y, z;
    bool bNeedUpdate;
    struct bench_node3D *next;
};

// --- 2. Structure of Arrays (SoA) ---
struct MoleculePool {
    double* x;
    double* y;
    double* z;
    bool* bNeedUpdate;
    size_t count;
};

// Simple pseudo-random generator for consistent load
double get_random_step() {
    return ((double)rand() / RAND_MAX) - 0.5;
}

// Baseline: Linked List
double benchmark_linked_list(size_t num_molecules) {
    struct bench_node3D* head = NULL;
    for (size_t i = 0; i < num_molecules; i++) {
        struct bench_node3D* new_node = (struct bench_node3D*)malloc(sizeof(struct bench_node3D));
        new_node->x = 0.0;
        new_node->y = 0.0;
        new_node->z = 0.0;
        new_node->bNeedUpdate = true;
        new_node->next = head;
        head = new_node;
    }

    clock_t start = clock();

    for (int step = 0; step < NUM_STEPS; step++) {
        struct bench_node3D* current = head;
        while (current != NULL) {
            current->x += 0.1;
            current->y += 0.1;
            current->z += 0.1;
            current = current->next;
        }
    }

    clock_t end = clock();
    double cpu_time_used = ((double) (end - start)) / CLOCKS_PER_SEC;

    struct bench_node3D* current = head;
    while (current != NULL) {
        struct bench_node3D* next = current->next;
        free(current);
        current = next;
    }

    return cpu_time_used;
}

// Optimized: Structure of Arrays
double benchmark_soa(size_t num_molecules) {
    struct MoleculePool pool;
    pool.count = num_molecules;
    pool.x = (double*)malloc(num_molecules * sizeof(double));
    pool.y = (double*)malloc(num_molecules * sizeof(double));
    pool.z = (double*)malloc(num_molecules * sizeof(double));
    pool.bNeedUpdate = (bool*)malloc(num_molecules * sizeof(bool));

    for (size_t i = 0; i < num_molecules; i++) {
        pool.x[i] = 0.0;
        pool.y[i] = 0.0;
        pool.z[i] = 0.0;
        pool.bNeedUpdate[i] = true;
    }

    clock_t start = clock();

    for (int step = 0; step < NUM_STEPS; step++) {
        for (size_t i = 0; i < num_molecules; i++) {
            pool.x[i] += 0.1;
            pool.y[i] += 0.1;
            pool.z[i] += 0.1;
        }
    }

    clock_t end = clock();
    double cpu_time_used = ((double) (end - start)) / CLOCKS_PER_SEC;

    free(pool.x);
    free(pool.y);
    free(pool.z);
    free(pool.bNeedUpdate);

    return cpu_time_used;
}

static void diffuseMolecules_pool_bench(MicroMoleculePool* pool,
	const struct region* region,
	unsigned short molType,
	double sigma)
{
	size_t i;
	if(pool == NULL)
		return;
	if(pool->count == 0)
		return;
	if(!region->bDiffuse[molType] && !region->spec.bFlow[molType])
		return;
	for(i = 0; i < pool->count; i++)
		pool->bNeedUpdate[i] = true;
	for(i = 0; i < pool->count; i++)
	{
		double x;
		double y;
		double z;
		if(!pool->bNeedUpdate[i])
			continue;
		pool->bNeedUpdate[i] = false;
		x = pool->x[i];
		y = pool->y[i];
		z = pool->z[i];
		if(region->bDiffuse[molType])
		{
			x = generateNormal(x, sigma);
			y = generateNormal(y, sigma);
			z = generateNormal(z, sigma);
		}
		if(region->spec.bFlow[molType])
		{
			switch(region->spec.flowType[molType])
			{
				case FLOW_UNIFORM:
					x += region->flowConstant[molType][0];
					y += region->flowConstant[molType][1];
					z += region->flowConstant[molType][2];
					break;
			}
		}
		pool->x[i] = x;
		pool->y[i] = y;
		pool->z[i] = z;
	}
}

int main() {
    srand(42);
    size_t sizes[] = {100000, 1000000, 10000000};
    int num_sizes = sizeof(sizes) / sizeof(sizes[0]);
    printf("=== Performance Benchmark: Linked List (AoS) vs SoA ===\n");
    printf("Molecules\tSoA_Time(s)\tList_Time(s)\tSpeedup(SoA/List)\n");
    for (int i = 0; i < num_sizes; i++) {
        size_t n = sizes[i];
        double t_soa = benchmark_soa(n);
        double t_list = benchmark_linked_list(n);
        double speedup = t_list / t_soa;
        printf("%zu\t%f\t%f\t%f\n", n, t_soa, t_list, speedup);
    }
    rngInitialize(42);
    struct region region;
    double dt = 1e-4;
    double diff_coef = 1.0;
    region.bDiffuse = malloc(sizeof(bool));
    region.flowConstant = malloc(sizeof(double *));
    region.spec.bFlow = malloc(sizeof(bool));
    region.spec.bFlowLocal = malloc(sizeof(bool));
    region.spec.flowType = malloc(sizeof(unsigned short));
    region.spec.flowVector = malloc(sizeof(double *));
    region.spec.bMicro = true;
    region.spec.dt = dt;
    region.bFlow = false;
    region.bDiffuse[0] = diff_coef > 0.0;
    region.spec.bFlow[0] = false;
    region.spec.bFlowLocal[0] = false;
    region.spec.flowType[0] = FLOW_UNIFORM;
    region.flowConstant[0] = malloc(3 * sizeof(double));
    region.flowConstant[0][0] = 0.0;
    region.flowConstant[0][1] = 0.0;
    region.flowConstant[0][2] = 0.0;
    region.spec.flowVector[0] = malloc(3 * sizeof(double));
    region.spec.flowVector[0][0] = 0.0;
    region.spec.flowVector[0][1] = 0.0;
    region.spec.flowVector[0][2] = 0.0;
    double sigma = sqrt(2.0 * diff_coef * dt);
    printf("\n=== Realistic Diffusion Benchmark (AcCoRD RNG and API) ===\n");
    printf("Molecules\tSoA_Time(s)\tList_Time(s)\tSpeedup(SoA/List)\n");
    for (int i = 0; i < num_sizes; i++) {
        size_t n = sizes[i];
        double t_soa = 0.0;
        double t_list = 0.0;
        MicroMoleculePool pool;
        pool_init(&pool, n);
        for (size_t k = 0; k < n; k++) {
            pool_add_molecule(&pool, 0.0, 0.0, 0.0, true);
        }
        clock_t start_soa = clock();
        for (int step = 0; step < NUM_STEPS; step++) {
            diffuseMolecules_pool_bench(&pool, &region, 0, sigma);
        }
        clock_t end_soa = clock();
        t_soa = (double)(end_soa - start_soa) / CLOCKS_PER_SEC;
        pool_free(&pool);
        NodeMol3D* head = NULL;
        for (size_t k = 0; k < n; k++) {
            NodeMol3D* node = (NodeMol3D*)malloc(sizeof(NodeMol3D));
            node->item.x = 0.0;
            node->item.y = 0.0;
            node->item.z = 0.0;
            node->item.bNeedUpdate = true;
            node->next = head;
            head = node;
        }
        clock_t start_list = clock();
        for (int step = 0; step < NUM_STEPS; step++) {
            NodeMol3D* cur = head;
            while (cur != NULL) {
                cur->item.bNeedUpdate = true;
                cur = cur->next;
            }
            cur = head;
            while (cur != NULL) {
                if (cur->item.bNeedUpdate) {
                    cur->item.bNeedUpdate = false;
                    if (region.bDiffuse[0]) {
                        cur->item.x = generateNormal(cur->item.x, sigma);
                        cur->item.y = generateNormal(cur->item.y, sigma);
                        cur->item.z = generateNormal(cur->item.z, sigma);
                    }
                    if (region.spec.bFlow[0]) {
                        switch(region.spec.flowType[0]) {
                            case FLOW_UNIFORM:
                                cur->item.x += region.flowConstant[0][0];
                                cur->item.y += region.flowConstant[0][1];
                                cur->item.z += region.flowConstant[0][2];
                                break;
                        }
                    }
                }
                cur = cur->next;
            }
        }
        clock_t end_list = clock();
        t_list = (double)(end_list - start_list) / CLOCKS_PER_SEC;
        NodeMol3D* cur = head;
        while (cur != NULL) {
            NodeMol3D* next = cur->next;
            free(cur);
            cur = next;
        }
        double speedup_real = t_list / t_soa;
        printf("%zu\t%f\t%f\t%f\n", n, t_soa, t_list, speedup_real);
    }
    free(region.bDiffuse);
    free(region.flowConstant[0]);
    free(region.flowConstant);
    free(region.spec.bFlow);
    free(region.spec.bFlowLocal);
    free(region.spec.flowType);
    free(region.spec.flowVector[0]);
    free(region.spec.flowVector);
    return 0;
}
