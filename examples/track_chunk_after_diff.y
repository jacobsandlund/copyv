// This example verifies that when the chunk lies entirely after every diff
// hunk between the base and the new file, the line-range shift is applied
// in the correct direction (i.e. new = base + delta, not base - delta).
// copyv: https://github.com/sqlite/sqlite/blob/7a0a0a22e774a7f6bc9e0cb14a18a33b396654d6/src/parse.y#L2115-L2160 begin
/*
** The code generator needs some extra TK_ token values for tokens that
** are synthesized and do not actually appear in the grammar:
*/
%token
  COLUMN          /* Reference to a table column */
  AGG_FUNCTION    /* An aggregate function */
  AGG_COLUMN      /* An aggregated column */
  TRUEFALSE       /* True or false keyword */
  ISNOT           /* Combination of IS and NOT */
  FUNCTION        /* A function invocation */
  UPLUS           /* Unary plus */
  UMINUS          /* Unary minus */
  TRUTH           /* IS TRUE or IS FALSE or IS NOT TRUE or IS NOT FALSE */
  REGISTER        /* Reference to a VDBE register */
  VECTOR          /* Vector */
  SELECT_COLUMN   /* Choose a single column from a multi-column SELECT */
  IF_NULL_ROW     /* the if-null-row operator */
  ASTERISK        /* The "*" in count(*) and similar */
  SPAN            /* The span operator */
  ERROR           /* An expression containing an error */
.

term(A) ::= QNUMBER(X). {
  A=tokenExpr(pParse,@X,X);
  sqlite3DequoteNumber(pParse, A);
}

/* There must be no more than 255 tokens defined above.  If this grammar
** is extended with new rules and tokens, they must either be so few in
** number that TK_SPAN is no more than 255, or else the new tokens must
** appear after this line.
*/
%include {
#if TK_SPAN>255
# error too many tokens in the grammar
#endif
}

/*
** The TK_SPACE, TK_COMMENT, and TK_ILLEGAL tokens must be the last three
** tokens.  The parser depends on this.  Those tokens are not used in any
** grammar rule.  They are only used by the tokenizer.  Declare them last
** so that they are guaranteed to be the last three.
*/
%token SPACE COMMENT ILLEGAL.
/* copyv: end */
