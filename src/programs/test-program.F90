PROGRAM TEST_PROGRAM

USE PARKIND1, ONLY: JPIM, JPRB
USE MPL_MODULE

IMPLICIT NONE

! Spectral truncation
INTEGER(JPIM), PARAMETER :: TRUNC = 79
INTEGER(JPIM) :: verbosity = 0

! Arrays for storing our field in spectral space and grid point space
REAL(KIND=JPRB), ALLOCATABLE :: SPECTRAL_FIELD(:,:)
REAL(KIND=JPRB), ALLOCATABLE :: SPECTRAL_FIELD_2(:,:)
REAL(KIND=JPRB), ALLOCATABLE :: GRID_POINT_FIELD(:,:,:)

! Dimensions of our arrays in spectral space and grid point space
INTEGER(KIND=JPIM) :: NSPEC2
INTEGER(KIND=JPIM) :: NGPTOT

INTEGER(KIND=JPIM) :: SPECTRAL_INDICES(0:TRUNC)

#include "setup_trans0.h"
#include "setup_trans.h"
#include "trans_inq.h"
#include "inv_trans.h"
#include "dir_trans.h"
#include "trans_end.h"

CALL MPL_INIT(ldinfo=(verbosity>=1))

CALL DR_HOOK_INIT()

! Initialise ecTrans (resolution-agnostic aspects)
CALL SETUP_TRANS0(LDMPOFF=.TRUE., KPRINTLEV=VERBOSITY)

! Initialise ecTrans (resolution-specific aspects)
CALL SETUP_TRANS(KSMAX=TRUNC, KDGL=2 * (TRUNC + 1))

! Inquire about the dimensions in spectral space and grid point space
CALL TRANS_INQ(KSPEC2=NSPEC2, KGPTOT=NGPTOT, KASM0=SPECTRAL_INDICES)

! Allocate our work arrays
ALLOCATE(SPECTRAL_FIELD(1,NSPEC2))
ALLOCATE(SPECTRAL_FIELD_2(1,NSPEC2))
ALLOCATE(GRID_POINT_FIELD(NGPTOT,1,1))

! Initialise our spectral field arrays
SPECTRAL_FIELD(:,:) = 0.0_JPRB
SPECTRAL_FIELD(1,SPECTRAL_INDICES(3) + 2 * 5 + 1) = 1.0_JPRB

! Perform an inverse transform
CALL INV_TRANS(PSPSCALAR=SPECTRAL_FIELD, PGP=GRID_POINT_FIELD)

WRITE(6,*) "GRID_POINT_FIELD = ", MINVAL(GRID_POINT_FIELD), MAXVAL(GRID_POINT_FIELD)
FLUSH(6)

! Perform a direct transform
CALL DIR_TRANS(PGP=GRID_POINT_FIELD, PSPSCALAR=SPECTRAL_FIELD_2)

WRITE(6,*) "TEST_PROGRAM 1"
FLUSH(6)

! Compute error between before and after fields
WRITE(6,*) "Error = ", NORM2(SPECTRAL_FIELD_2 - SPECTRAL_FIELD)
FLUSH(6)

CALL TRANS_END

CALL MPL_END(ldmeminfo=.false.)

END PROGRAM TEST_PROGRAM
