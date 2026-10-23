// Prefracture a mesh into Voronoi chunks with the NVIDIA Blast SDK's authoring library.
//
//     blast-fracture --out chunks.obj [--cells N] [--seed S]
//                    (--box W D H | --obj mesh.obj)
//
// The box is W (x) by D (y) by H (z) meters, standing on z = 0; an OBJ brings a mesh of
// your own (triangles or quads, meters). The output OBJ holds one group per chunk,
// with the cut faces under "usemtl interior" and the original surface under
// "usemtl exterior", in the input's coordinates; make-scene.py turns it into USD.
// Built by build.sh against the Blast SDK (BSD-3, github.com/NVIDIA-Omniverse/PhysX,
// blast/), which has no Kit extension for Kit 110.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include "NvBlastExtAuthoring.h"
#include "NvBlastExtAuthoringFractureTool.h"
#include "NvBlastExtAuthoringMesh.h"
#include "NvBlastExtAuthoringTypes.h"

using namespace Nv::Blast;

struct Rng : public RandomGeneratorBase {
    std::mt19937 engine;
    float getRandomValue() override { return std::uniform_real_distribution<float>(0.0f, 1.0f)(engine); }
    void seed(int32_t s) override { engine.seed(static_cast<uint32_t>(s)); }
};

struct Input {
    std::vector<NvcVec3> positions, normals;
    std::vector<NvcVec2> uvs;
    std::vector<uint32_t> indices;
};

static void addTriangle(Input& in, NvcVec3 a, NvcVec3 b, NvcVec3 c) {
    NvcVec3 u = {b.x - a.x, b.y - a.y, b.z - a.z}, v = {c.x - a.x, c.y - a.y, c.z - a.z};
    NvcVec3 n = {u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    float len = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (len > 0) { n.x /= len; n.y /= len; n.z /= len; }
    for (NvcVec3 p : {a, b, c}) {
        in.indices.push_back(static_cast<uint32_t>(in.positions.size()));
        in.positions.push_back(p);
        in.normals.push_back(n);
        in.uvs.push_back({p.x, p.z});
    }
}

static Input boxMesh(float w, float d, float h) {
    Input in;
    float x = w / 2, y = d / 2;
    NvcVec3 c[8] = {{-x, -y, 0}, {x, -y, 0}, {x, y, 0}, {-x, y, 0}, {-x, -y, h}, {x, -y, h}, {x, y, h}, {-x, y, h}};
    int faces[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
    for (auto& f : faces) {
        addTriangle(in, c[f[0]], c[f[1]], c[f[2]]);
        addTriangle(in, c[f[0]], c[f[2]], c[f[3]]);
    }
    return in;
}

static Input objMesh(const std::string& path) {
    std::ifstream file(path);
    if (!file) { std::fprintf(stderr, "cannot read %s\n", path.c_str()); std::exit(1); }
    std::vector<NvcVec3> verts;
    Input in;
    std::string line;
    while (std::getline(file, line)) {
        std::istringstream s(line);
        std::string tag;
        s >> tag;
        if (tag == "v") {
            NvcVec3 p; s >> p.x >> p.y >> p.z; verts.push_back(p);
        } else if (tag == "f") {
            std::vector<int> ids;
            std::string item;
            while (s >> item) {
                int id = std::atoi(item.substr(0, item.find('/')).c_str());
                ids.push_back(id < 0 ? static_cast<int>(verts.size()) + id : id - 1);
            }
            for (size_t i = 1; i + 1 < ids.size(); ++i)
                addTriangle(in, verts[ids[0]], verts[ids[i]], verts[ids[i + 1]]);
        }
    }
    if (in.indices.empty()) { std::fprintf(stderr, "no faces in %s\n", path.c_str()); std::exit(1); }
    return in;
}

int main(int argc, char** argv) {
    std::string out, obj;
    float w = 2.4f, d = 0.2f, h = 1.2f;
    uint32_t cells = 24;
    int32_t seed = 7;
    bool box = false;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](float& v) { v = std::strtof(argv[++i], nullptr); };
        if (a == "--out") out = argv[++i];
        else if (a == "--obj") obj = argv[++i];
        else if (a == "--cells") cells = static_cast<uint32_t>(std::atoi(argv[++i]));
        else if (a == "--seed") seed = std::atoi(argv[++i]);
        else if (a == "--box") { box = true; next(w); next(d); next(h); }
        else { std::fprintf(stderr, "unknown argument %s\n", a.c_str()); return 1; }
    }
    if (out.empty() || (obj.empty() && !box)) {
        std::fprintf(stderr, "usage: blast-fracture --out chunks.obj [--cells N] [--seed S] (--box W D H | --obj mesh.obj)\n");
        return 1;
    }
    Input in = obj.empty() ? boxMesh(w, d, h) : objMesh(obj);
    Mesh* mesh = NvBlastExtAuthoringCreateMesh(in.positions.data(), in.normals.data(), in.uvs.data(),
                                               static_cast<uint32_t>(in.positions.size()),
                                               in.indices.data(), static_cast<uint32_t>(in.indices.size()));
    if (!mesh || !mesh->isValid()) { std::fprintf(stderr, "Blast rejected the input mesh\n"); return 1; }

    FractureTool* tool = NvBlastExtAuthoringCreateFractureTool();
    tool->setSourceMeshes(&mesh, 1);
    tool->setInteriorMaterialId(1);
    Rng rng;
    rng.seed(seed);
    VoronoiSitesGenerator* sites = NvBlastExtAuthoringCreateVoronoiSitesGenerator(mesh, &rng);
    sites->uniformlyGenerateSitesInMesh(cells);
    const NvcVec3* points = nullptr;
    uint32_t count = sites->getVoronoiSites(points);
    if (tool->voronoiFracturing(0, count, points, false) != 0) { std::fprintf(stderr, "Voronoi fracturing failed\n"); return 1; }
    tool->finalizeFracturing();

    std::FILE* f = std::fopen(out.c_str(), "w");
    if (!f) { std::fprintf(stderr, "cannot write %s\n", out.c_str()); return 1; }
    std::fprintf(f, "# %u Voronoi chunks from the NVIDIA Blast SDK (seed %d); interior = cut faces\n", count, seed);
    uint32_t vertexBase = 1, chunks = 0;
    for (uint32_t i = 0; i < tool->getChunkCount(); ++i) {
        const ChunkInfo& info = tool->getChunkInfo(static_cast<int32_t>(i));
        if (!info.isLeaf) continue;
        Triangle* tris = nullptr;
        uint32_t n = tool->getBaseMesh(static_cast<int32_t>(i), tris);
        std::fprintf(f, "g chunk_%u\n", chunks);
        for (uint32_t t = 0; t < n; ++t)
            for (const Vertex* v : {&tris[t].a, &tris[t].b, &tris[t].c})
                std::fprintf(f, "v %.6f %.6f %.6f\n", v->p.x, v->p.y, v->p.z);
        int material = -1;
        for (uint32_t t = 0; t < n; ++t) {
            if (tris[t].materialId != material) {
                material = tris[t].materialId;
                std::fprintf(f, "usemtl %s\n", material == 1 ? "interior" : "exterior");
            }
            std::fprintf(f, "f %u %u %u\n", vertexBase + 3 * t, vertexBase + 3 * t + 1, vertexBase + 3 * t + 2);
        }
        vertexBase += 3 * n;
        delete[] tris;
        ++chunks;
    }
    std::fclose(f);
    std::printf("%u chunks written to %s\n", chunks, out.c_str());
    sites->release();
    tool->release();
    mesh->release();
    return 0;
}
