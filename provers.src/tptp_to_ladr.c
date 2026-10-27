/*  Copyright (C) 2006, 2007 William McCune

    This file is part of the LADR Deduction Library.

    The LADR Deduction Library is free software; you can redistribute it
    and/or modify it under the terms of the GNU General Public License,
    version 2.

    The LADR Deduction Library is distributed in the hope that it will be
    useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with the LADR Deduction Library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
*/

#include "../ladr/top_input.h"
#include <ctype.h>

#define PROGRAM_NAME    "tptp_to_ladr"
#include "../VERSION_DATE.h"

/*************
 *
 *   distinct objects
 *
 *************/

/* TPTP has a token that LADR has no counterpart for: the "distinct
 * object", written in double quotes.  TPTP's syntax document says they
 * are different from (but may be equal to) other terms, so
 * "Apple" != "Microsoft" is implicit, while "cat" = cat may hold.
 *
 * LADR's reader quotes with ' here (set_quote_char() in main), so a
 * double quote is not even lexable, and every problem containing one
 * failed with "sread_term error".  Mapping them to LADR numerals is not
 * an option either: LADR has no numeral for "3.44".
 *
 * So the input is rewritten before it is parsed: each distinct object
 * becomes a fresh constant DO_PREFIX<n>, and main() states their pairwise
 * inequality explicitly, as n(n-1)/2 unit disequalities.  Nothing is said
 * about whether a distinct object equals an ordinary term, which is
 * correct: TPTP permits "cat" = cat.
 */

#define DO_PREFIX "tptp_do_"

static Plist Distinct_objects = NULL;  /* texts, in order of first sighting */
static int Distinct_count = 0;
static BOOL Do_prefix_in_input = FALSE;  /* input already uses DO_PREFIX */

static
int distinct_object_index(char *text)
{
  Plist p;
  int i = 0;
  for (p = Distinct_objects; p != NULL; p = p->next, i++)
    if (str_ident(text, p->v))
      return i;
  Distinct_objects = plist_append(Distinct_objects, new_str_copy(text));
  return Distinct_count++;
}  /* distinct_object_index */

static
int peek_char(FILE *fp)
{
  int c = getc(fp);
  if (c != EOF)
    ungetc(c, fp);
  return c;
}  /* peek_char */

/* Copy one TPTP stream to a temporary file, replacing each distinct
   object by its constant.  Comments and single-quoted atoms are copied
   unchanged, so a double quote inside one is left alone.  A slash-star
   block comment is blanked instead: it is legal TPTP that LADR's reader
   does not know, and it may contain quotes of either kind. */

static
FILE *rewrite_distinct_objects(FILE *fin)
{
  FILE *fout = tmpfile();
  int c;

  if (fout == NULL)
    fatal_error("rewrite_distinct_objects, cannot create a temporary file");

  while ((c = getc(fin)) != EOF) {
    if (c == '%') {                          /* line comment */
      do
	putc(c, fout);
      while ((c = getc(fin)) != EOF && c != '\n');
      if (c == '\n')
	putc(c, fout);
    }
    else if (c == '/' && peek_char(fin) == '*') {  /* block comment */
      int prev = 0;
      getc(fin);
      fputs("  ", fout);
      while ((c = getc(fin)) != EOF && !(prev == '*' && c == '/')) {
	putc(c == '\n' ? '\n' : ' ', fout);
	prev = c;
      }
      if (c != EOF)
	putc(' ', fout);
    }
    else if (c == '\'') {                    /* single-quoted atom */
      putc(c, fout);
      while ((c = getc(fin)) != EOF && c != '\'') {
	putc(c, fout);
	if (c == '\\' && (c = getc(fin)) != EOF)
	  putc(c, fout);
      }
      if (c != EOF)
	putc(c, fout);
    }
    else if (c == '"') {                     /* distinct object */
      String_buf sb = get_string_buf();
      char *text;
      while ((c = getc(fin)) != EOF && c != '"') {
	sb_append_char(sb, c);
	if (c == '\\' && (c = getc(fin)) != EOF)
	  sb_append_char(sb, c);
      }
      text = sb_to_malloc_string(sb);
      zap_string_buf(sb);
      fprintf(fout, DO_PREFIX "%d", distinct_object_index(text));
      safe_free(text);
    }
    else if (isalnum(c) || c == '_') {       /* a word */
      /* Watch for a word that starts with the prefix the distinct
	 objects are renamed to.  Comments and quoted atoms, handled
	 above, may mention it without causing a collision. */
      char head[sizeof(DO_PREFIX)];
      int n = 0;
      do {
	putc(c, fout);
	if (n < (int) sizeof(head) - 1)
	  head[n++] = c;
      } while ((c = getc(fin)) != EOF && (isalnum(c) || c == '_'));
      head[n] = '\0';
      if (str_ident(head, DO_PREFIX))
	Do_prefix_in_input = TRUE;
      if (c != EOF)
	ungetc(c, fin);
    }
    else
      putc(c, fout);
  }
  rewind(fout);
  return fout;
}  /* rewrite_distinct_objects */

/* The pairwise disequalities, as TPTP text, so that the ordinary reader
   takes care of them. */

static
FILE *distinctness_axioms(void)
{
  FILE *fp = tmpfile();
  int i, j;

  if (fp == NULL)
    fatal_error("distinctness_axioms, cannot create a temporary file");
  for (i = 0; i < Distinct_count; i++)
    for (j = i + 1; j < Distinct_count; j++)
      fprintf(fp, "fof(%sax_%d_%d, axiom, %s%d != %s%d).\n",
	      DO_PREFIX, i, j, DO_PREFIX, i, DO_PREFIX, j);
  rewind(fp);
  return fp;
}  /* distinctness_axioms */

/*************
 *
 *   read_tptp_input()
 *
 *************/

static
void read_tptp_input(FILE *fin, FILE *fout, FILE *ferr,
		     Plist *assumps, Plist *goals, int depth)
{
  Term t = read_term(fin, fout);

  while (t != NULL) {

    if (is_term(t, "include", 1) || is_term(t, "include", 2)) {
      char *fname = new_str_copy(sn_to_str(SYMNUM(ARG(t,0))));
      char *fname2 = fname;
      FILE *fin2;

      if (depth >= 20)
	fatal_error("read_tptp_input: include depth limit (20) exceeded");

      if (*fname2 == '\'' || *fname2 == '"') {
	fname2[strlen(fname2)-1] = '\0';
	fname2++;
      }
      fin2 = fopen(fname2, "r");
      if (fin2 == NULL) {
	char s[100];
	snprintf(s, sizeof(s), "read_tptp_input, file %.60s not found", fname2);
	fatal_error(s);
      }
      fprintf(fout, "\n%% Including file %s\n\n", fname2);
      {
	FILE *rew = rewrite_distinct_objects(fin2);
	fclose(fin2);
	read_tptp_input(rew, fout, ferr, assumps, goals, depth + 1);
	fclose(rew);
      }
      safe_free(fname);
    }
    else if (is_term(t, "cnf", 3) || is_term(t, "cnf", 4) ||
	     is_term(t, "fof", 3) || is_term(t, "fof", 4) ||
	     is_term(t, "input_clause", 3)) {
      Formula form = tptp_input_to_ladr_formula(t);
      if (is_term(ARG(t,1), "conjecture", 0))
	*goals = plist_prepend(*goals, form);
      else
	*assumps = plist_prepend(*assumps, form);
    }
    else {
      p_term(t);
      fatal_error("read_tptp_input: unknown term");
    }
    zap_term(t);
    t = read_term(fin, fout);
  }
}  /* read_tptp_input */

int main(int argc, char **argv)
{
  Plist assumps = NULL;
  Plist goals = NULL;
  Plist all = NULL;
  Plist p;

  Ilist fp_syms = NULL;
  I2list map;

  BOOL quote_bad_ladr_syms = string_member("-q", argv, argc);

  init_standard_ladr();
  (void) register_attribute("label",  STRING_ATTRIBUTE);

  clear_parse_type_for_all_symbols();
  declare_tptp_input_types();
  set_quote_char('\'');  /* TPTP uses single quotes for strings. */

  {
    FILE *rew = rewrite_distinct_objects(stdin);
    read_tptp_input(rew, stdout, stderr, &assumps, &goals, 0);
    fclose(rew);
  }

  /* Distinct objects are pairwise unequal; say so.  The generated names
     must not collide with anything the input already uses. */

  if (Distinct_count > 0) {
    if (Do_prefix_in_input)
      fatal_error("tptp_to_ladr: the input already uses the name prefix "
		  DO_PREFIX ", which distinct objects are renamed to");
    printf("\n%% The TPTP formulas contain %d distinct object(s) (the \"...\"\n"
	   "%% token).  LADR has no such notion, so each one became a constant\n"
	   "%% named " DO_PREFIX "<n>, and their pairwise inequality, which TPTP\n"
	   "%% leaves implicit, is stated explicitly below, as %d disequalities.\n",
	   Distinct_count, (Distinct_count * (Distinct_count - 1)) / 2);
    if (Distinct_count > 1) {
      FILE *ax = distinctness_axioms();
      read_tptp_input(ax, stdout, stderr, &assumps, &goals, 0);
      fclose(ax);
    }
  }

  assumps = reverse_plist(assumps);
  goals = reverse_plist(goals);

  /* Collect all of the LADR terms into one list. */

  all = NULL;
  all = plist_cat2(all, assumps);
  all = plist_cat2(all, goals);

  /* Collect all of the function and predicate symbols. */

  {
    int sn = greatest_symnum() + 1;
    int *rcounts = safe_calloc(sn, sizeof(int));
    int *fcounts = safe_calloc(sn, sizeof(int));
    Ilist rsyms, fsyms;
    gather_symbols_in_formulas(all, rcounts, fcounts);
    rsyms = counts_to_set(rcounts, sn);
    fsyms = counts_to_set(fcounts, sn);
    safe_free(rcounts);
    safe_free(fcounts);
    fp_syms = ilist_cat(rsyms, fsyms);
  }

  /* Determine which symbols are bad for LADR and create a map to new ones. */

  map = map_for_bad_ladr_syms(fp_syms, quote_bad_ladr_syms);

  /* Replace the bad symbols. */

  if (map != NULL) {
    I2list b;
    printf("\n%% The TPTP formulas contain function or predicate symbols\n"
	   "%% that are not legal LADR symbols, and we have replaced those\n"
	   "%% symbols with new symbols.  Here is the list of the unaccepted\n"
	   "%% symbols and the corresponding replacements.\n%%\n");
    for (b = map; b; b = b->next)
      printf("%%   (arity %d) %8s    %s\n",
	     sn_to_arity(b->j),
	     sn_to_str(b->i),
	     sn_to_str(b->j));
    printf("\n");
    for (p = assumps; p; p = p->next) {
      Term t = formula_to_term(p->v);
      Term t2 = replace_bad_syms_term(t, map);
      p->v = term_to_formula(t2);
    }
    for (p = goals; p; p = p->next) {
      Formula f = p->v;
      Term t = formula_to_term(f);
      zap_formula(f);
      t = replace_bad_syms_term(t, map);
      p->v = term_to_formula(t);
      zap_term(t);
    }
  }

  /* Change settings for LADR output. */  

  clear_parse_type_for_all_symbols();
  declare_standard_parse_types();  /* defaults for LADR */

  /* Output the LADR terms. */

  printf("set(prolog_style_variables).\n");

  /* The distinctness axioms are negative unit clauses, and prover9's
     auto_denials heuristic takes a Horn set with several negative
     clauses to be a set of candidate goals: it raises max_proofs to
     their number and attaches answer literals to them.  They are not
     goals, so say so -- to prover9 only, since mace4 does not know the
     flag. */

  if (Distinct_count > 1)
    printf("if(Prover9).  %% the distinctness axioms are not goals\n"
	   "  clear(auto_denials).\n"
	   "end_if.\n");
  fwrite_formula_list(stdout, assumps, "assumptions");
  fwrite_formula_list(stdout, goals, "goals");

  exit(0);
}  /* main */

