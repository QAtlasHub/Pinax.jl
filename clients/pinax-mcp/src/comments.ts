// CommentStore — read/append the Pinax comment sidecar (`comments.toml`), byte-compatible with
// Julia's `Pinax.read_comments` / `Pinax.add_comment`. This is the LLM end of the comment loop:
// an agent appends a turn here, the human re-renders, and the comment is baked into the gallery.
//
// The TOML shape (see src/comments.jl) is id-keyed append-only array-of-tables plus a bookmark table:
//
//     [[comment.eq_energy]]
//     author = "llm"
//     text   = "Residual growth is consistent with finite-χ truncation."
//
//     [bookmark]
//     eq_energy = true
//
// `text` is arbitrary markdown, so we never hand-roll TOML — smol-toml handles string escaping and
// key quoting, and Julia's TOML stdlib reads the result back.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { parse, stringify } from "smol-toml";

export interface CommentTurn {
  author: string;
  text: string;
}

export class CommentStore {
  constructor(readonly path: string) {}

  // The store as data. A file that does not parse reads as empty (as Julia's read_comments does, with
  // a diagnostic), except for a write: writing the empty store back would erase what a person wrote,
  // so `forWrite` refuses instead, naming the file.
  private read(forWrite = false): Record<string, any> {
    if (!existsSync(this.path)) return {};
    try {
      return parse(readFileSync(this.path, "utf8")) as Record<string, any>;
    } catch (e) {
      if (forWrite)
        throw new Error(`${this.path} does not parse, so it is left as it is: ${(e as Error).message}`);
      return {};
    }
  }

  private write(data: Record<string, any>): void {
    mkdirSync(dirname(this.path), { recursive: true });
    writeFileSync(this.path, stringify(data));
  }

  /** Append one comment turn for `id`, preserving existing turns and bookmarks (Pinax.add_comment). */
  addComment(id: string, text: string, author = ""): CommentTurn[] {
    const data = this.read(true);
    const comment = (data.comment ??= {});
    const turns = (comment[id] ??= []) as CommentTurn[];
    if (!Array.isArray(turns))
      throw new Error(
        `${this.path}: [comment.${id}] is one table, not a list of turns: write each turn as [[comment.${id}]]`,
      );
    turns.push({ author, text });
    this.write(data);
    return this.comments(id);
  }

  /** Mark/unmark `id` as bookmarked (Pinax.set_bookmark!). */
  setBookmark(id: string, on: boolean): void {
    const data = this.read(true);
    (data.bookmark ??= {})[id] = on;
    this.write(data);
  }

  /** Existing turns for `id`, in file order. */
  comments(id: string): CommentTurn[] {
    const c = this.read().comment?.[id];
    return Array.isArray(c)
      ? c.map((e: any) => ({ author: String(e.author ?? ""), text: String(e.text ?? "") }))
      : [];
  }
}
