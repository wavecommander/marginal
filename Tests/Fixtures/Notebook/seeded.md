# no-outline

## Front matter

**Page 1**

Course plan: chapters 3 to 5 before the midterm, one section a day.

## 3 Matrices and Linear Maps

**Page 4**

> A linear map is determined by what it does to a basis. (p. 4)

**Page 5**

Composition of maps is matrix multiplication, read right to left.

## 4 Determinants

**Page 10**

> The determinant of a product is the product of the determinants. (p. 10)

**Page 12**

Row operations: a swap flips the sign, scaling a row scales the determinant.

## 5 Eigenvalues and Eigenvectors

Everything in this chapter leans on Chapter 4: an eigenvalue is a number that makes A − λI singular. Reread 4.3 if 5.2 feels shaky.

### 5.1 Invariant Directions

An eigenvector is a direction the map only stretches. A shear has just one such direction; a projection has eigenvalues 0 and 1.

**Page 17**

Figure 5.2 is the picture to remember: most arrows turn, two lines do not.

**Page 19**

> An eigenvector is never the zero vector, but an eigenvalue may be zero. (p. 19)

### 5.2 The Characteristic Equation

Big idea. Eigenvalues are the roots of det(A − λI). A geometric question becomes an algebra problem.

**Page 23**

Motivation: guessing eigenvectors doesn't scale past 2 × 2.

**Page 25**

Why the determinant shows up. (A − λI)v = 0 needs a nonzero v, so A − λI has to flatten some direction to zero. That means singular, and singular means det = 0.

![Handwritten note](images/note-001.png)

> A nonzero solution v exists exactly when the matrix A − λI is singular (p. 25)

> an n × n matrix has at most n distinct eigenvalues (p. 25)

**Page 28**

Triangular case: det is the product of the diagonal, so the roots are the diagonal entries.

**Page 29**

> The eigenvalues of a triangular matrix are the entries on its main diagonal. (p. 29)
