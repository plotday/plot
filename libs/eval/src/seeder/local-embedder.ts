/**
 * Local embedding inference for the eval corpus backfill (spec D).
 *
 * Uses `@huggingface/transformers` with `Xenova/bge-small-en-v1.5` — the same
 * weights as prod's Workers AI `@cf/baai/bge-small-en-v1.5` — with MEAN pooling
 * and L2 normalization on the raw title text (prod passes raw text, no query
 * instruction). dtype is pinned to fp32 so quantization cannot skew the
 * parity-gate cosines.
 *
 * Pooling was determined EMPIRICALLY against prod vectors (2026-06-11 kris
 * extraction): CLS pooling gave cosines 0.93–0.97 vs stored prod embeddings;
 * mean pooling gives 0.999999–1.000000 on the same five titles. Workers AI's
 * bge-small endpoint mean-pools despite the BGE paper recommending CLS. Do
 * not "fix" this back to CLS without re-running the parity gate.
 *
 * The model (~130MB ONNX) downloads to the local Hugging Face cache on first
 * use and runs offline afterwards. Unit tests must never call this module's
 * embedTitle — only the CLI smoke run and real backfills do.
 */
import {
  pipeline,
  type FeatureExtractionPipeline,
} from "@huggingface/transformers";

const MODEL_ID = "Xenova/bge-small-en-v1.5";

/** Lazy singleton: the pipeline (and model download) initializes on first use. */
let extractor: Promise<FeatureExtractionPipeline> | null = null;

function getExtractor(): Promise<FeatureExtractionPipeline> {
  extractor ??= pipeline("feature-extraction", MODEL_ID, { dtype: "fp32" }).catch(
    (err) => {
      extractor = null;
      throw err;
    }
  );
  return extractor;
}

/** Embeds a thread title into a 384-dim L2-normalized vector (mean pooling). */
export async function embedTitle(text: string): Promise<number[]> {
  const extract = await getExtractor();
  const output = await extract(text, { pooling: "mean", normalize: true });
  const vector = Array.from(output.data as Float32Array);
  if (vector.length !== 384) {
    throw new Error(
      `local-embedder: expected a 384-dim vector, got ${vector.length}`
    );
  }
  return vector;
}
