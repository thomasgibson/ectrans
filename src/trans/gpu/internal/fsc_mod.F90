! (C) Copyright 2000- ECMWF.
! (C) Copyright 2000- Meteo-France.
! (C) Copyright 2022- NVIDIA.
!
! This software is licensed under the terms of the Apache Licence Version 2.0
! which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
! In applying this licence, ECMWF does not waive the privileges and immunities
! granted to it by virtue of its status as an intergovernmental organisation
! nor does it submit to any jurisdiction.
!

MODULE FSC_MOD
  USE BUFFERED_ALLOCATOR_MOD, ONLY: BUFFERED_ALLOCATOR
  USE PARKIND_ECTRANS,        ONLY: JPIM, JPRBT
  USE TPM_DISTR,              ONLY: D
  IMPLICIT NONE

  PRIVATE
  PUBLIC :: FSC, PREPARE_FSC, FSC_HANDLE

  TYPE FSC_HANDLE
  END TYPE

CONTAINS
  FUNCTION PREPARE_FSC(ALLOCATOR) RESULT(HFSC)
    IMPLICIT NONE

    TYPE(BUFFERED_ALLOCATOR), INTENT(INOUT) :: ALLOCATOR
    TYPE(FSC_HANDLE) :: HFSC
  END FUNCTION
SUBROUTINE FSC(ALLOCATOR,HFSC,PREEL_COMPLEX, KF_FS, KF_UV, KF_SCALARS, KUV_OFFSET, &
        & KSCALARS_OFFSET, KSCALARS_NSDER_OFFSET, KUV_EWDER_OFFSET, KSCALARS_EWDER_OFFSET)

!**** *FSC - Division by a*cos(theta), east-west derivatives

!     Purpose.
!     --------
!        In Fourier space divide u and v and all north-south
!        derivatives by a*cos(theta). Also compute east-west derivatives
!        of u,v,thermodynamic, passiv scalar variables and surface
!        pressure.

!**   Interface.
!     ----------
!        CALL FSC(..)
!        Explicit arguments :  KF_FS - total stride
!        --------------------  KF_UV - # uv layers
!                              KF_SCALARS - # scalar layers
!                              *_OFFSET - offset of the respective layer
!
!     Method.
!     -------

!     Externals.   None.
!     ----------

!     Author.
!     -------
!        Mats Hamrud *ECMWF*

!     Modifications.
!     --------------
!        Original : 00-03-03 (From SC2FSC)

!     ------------------------------------------------------------------

USE TPM_TRANS,       ONLY: LATLON
USE TPM_DISTR,       ONLY: MYSETW,  MYPROC, NPROC, D_NUMP, D_NPTRLS, D_NSTAGTF
USE TPM_GEOMETRY,    ONLY: G_NMEN, G_NLOEN, G_NLOEN_MAX
USE TPM_FIELDS_FLAT, ONLY: F_RACTHE
USE TPM_GEN,         ONLY: NOUT
USE TPM_DIM,         ONLY: R_NSMAX
!

IMPLICIT NONE
REAL(KIND=JPRBT), INTENT(INOUT) :: PREEL_COMPLEX(:)
INTEGER(KIND=JPIM), INTENT(IN) :: KF_FS, KF_UV, KF_SCALARS
INTEGER(KIND=JPIM), INTENT(IN) :: KUV_OFFSET, KSCALARS_OFFSET, KSCALARS_NSDER_OFFSET, KUV_EWDER_OFFSET, KSCALARS_EWDER_OFFSET
TYPE(BUFFERED_ALLOCATOR), INTENT(IN) :: ALLOCATOR
TYPE(FSC_HANDLE), INTENT(IN) :: HFSC

INTEGER(KIND=JPIM) :: KGL

REAL(KIND=JPRBT) :: ZACHTE2
REAL(KIND=JPRBT) :: ZAMP, ZPHASE
INTEGER(KIND=JPIM) :: IOFF_LAT,OFFSET_VAR
INTEGER(KIND=JPIM) :: IOFF_SCALARS,IOFF_SCALARS_EWDER,IOFF_UV,IOFF_UV_EWDER,IOFF_KSCALARS_NSDER
INTEGER(KIND=JPIM) :: JF,IGLG,II,JM
INTEGER(KIND=JPIM) :: IBEG,IEND,IINC
REAL(KIND=JPRBT) :: RET_REAL, RET_COMPLEX


!     ------------------------------------------------------------------

IF(MYPROC > NPROC/2)THEN
  IBEG=1
  IEND=D%NDGL_FS
  IINC=1
ELSE
  IBEG=D%NDGL_FS
  IEND=1
  IINC=-1
ENDIF

#ifdef ACCGPU
!$ACC DATA &
!$ACC& PRESENT(D_NPTRLS,D_NSTAGTF,PREEL_COMPLEX,F_RACTHE,G_NMEN,G_NLOEN, G_NLOEN_MAX, R_NSMAX)
#endif
#ifdef OMPGPU
!$OMP TARGET DATA MAP(PRESENT,ALLOC:ZGTF) &
!$OMP& MAP(ALLOC:PUV,PSCALAR,PNSDERS,PEWDERS,PUVDERS)
#endif

!     ------------------------------------------------------------------

!*       1.    DIVIDE U V AND N-S DERIVATIVES BY A*COS(THETA)
!              ----------------------------------------------

OFFSET_VAR=D%NPTRLS(MYSETW)

!*       1.1      U AND V.
#ifdef OMPGPU
  !$OMP TARGET TEAMS DISTRIBUTE PARALLEL DO DEFAULT(NONE) SHARED(KF_UV,PUV,ZACHTE2)
#endif
#ifdef ACCGPU
!$ACC PARALLEL LOOP COLLAPSE(3) DEFAULT(NONE) PRIVATE(IGLG,IOFF_LAT,IOFF_UV,ZACHTE2,JM,JF,KGL) &
!$ACC& FIRSTPRIVATE(IBEG,IEND,IINC,OFFSET_VAR,KF_UV,KUV_OFFSET,KF_FS) ASYNC(1)
#endif
DO KGL=IBEG,IEND,IINC
  DO JF=1,2*KF_UV
    DO JM=0,R_NSMAX !(note that R_NSMAX <= G_NMEN(IGLG) for all IGLG)
      IGLG    = OFFSET_VAR+KGL-1
      IF (JM <= G_NMEN(IGLG)) THEN
        IOFF_LAT = KF_FS*D_NSTAGTF(KGL)
        IOFF_UV = IOFF_LAT+(KUV_OFFSET+JF-1)*(D_NSTAGTF(KGL+1)-D_NSTAGTF(KGL))

        ZACHTE2 = REAL(F_RACTHE(IGLG),JPRBT)

        PREEL_COMPLEX(IOFF_UV+2*JM+1) = &
            & PREEL_COMPLEX(IOFF_UV+2*JM+1)*ZACHTE2
        PREEL_COMPLEX(IOFF_UV+2*JM+2) = &
            & PREEL_COMPLEX(IOFF_UV+2*JM+2)*ZACHTE2
      ENDIF
    ENDDO
  ENDDO
ENDDO

!*      1.2      N-S DERIVATIVES

IF (KSCALARS_NSDER_OFFSET >= 0) THEN
#ifdef OMPGPU
  !$OMP TARGET TEAMS DISTRIBUTE PARALLEL DO DEFAULT(NONE) SHARED(KF_SCALARS,PNSDERS,ZACHTE2)
#endif
#ifdef ACCGPU
  !$ACC PARALLEL LOOP COLLAPSE(3) DEFAULT(NONE) PRIVATE(IGLG,IOFF_LAT,IOFF_KSCALARS_NSDER,ZACHTE2,KGL,JF,JM) &
  !$ACC& FIRSTPRIVATE(IBEG,IEND,IINC,OFFSET_VAR,KF_SCALARS,KSCALARS_NSDER_OFFSET,KF_FS) ASYNC(1)
#endif
  DO KGL=IBEG,IEND,IINC
    DO JF=1,KF_SCALARS
      DO JM=0,R_NSMAX !(note that R_NSMAX <= G_NMEN(IGLG) for all IGLG)
        IGLG = OFFSET_VAR+KGL-1
        IF (JM <= G_NMEN(IGLG)) THEN
          IOFF_LAT = KF_FS*D_NSTAGTF(KGL)
          IOFF_KSCALARS_NSDER = IOFF_LAT+(KSCALARS_NSDER_OFFSET+JF-1)*(D_NSTAGTF(KGL+1)-D_NSTAGTF(KGL))

          ZACHTE2 = REAL(F_RACTHE(IGLG),JPRBT)

          PREEL_COMPLEX(IOFF_KSCALARS_NSDER+2*JM+1) = &
              & PREEL_COMPLEX(IOFF_KSCALARS_NSDER+2*JM+1)*ZACHTE2
          PREEL_COMPLEX(IOFF_KSCALARS_NSDER+2*JM+2) = &
              & PREEL_COMPLEX(IOFF_KSCALARS_NSDER+2*JM+2)*ZACHTE2
        ENDIF
      ENDDO
    ENDDO
  ENDDO
ENDIF

!     ------------------------------------------------------------------

!*       2.    EAST-WEST DERIVATIVES
!              ---------------------

!*       2.1      U AND V.

IF (KUV_EWDER_OFFSET >= 0) THEN
#ifdef OMPGPU
  !$OMP TARGET TEAMS DISTRIBUTE PARALLEL DO DEFAULT(NONE) SHARED(KF_UV,PUVDERS,ZACHTE2,PUV)
#endif
#ifdef ACCGPU
  !$ACC PARALLEL LOOP COLLAPSE(3) DEFAULT(NONE) PRIVATE(IGLG,IOFF_LAT,IOFF_UV,IOFF_UV_EWDER,RET_REAL,RET_COMPLEX,ZACHTE2,JM,JF,KGL) &
  !$ACC& FIRSTPRIVATE(IBEG,IEND,IINC,OFFSET_VAR,KF_UV,KUV_EWDER_OFFSET,KUV_OFFSET,KF_FS) ASYNC(1)
#endif
  DO KGL=IBEG,IEND,IINC
    DO JF=1,2*KF_UV
      DO JM=0,G_NLOEN_MAX/2
        IGLG = OFFSET_VAR+KGL-1
        ! FFT transforms NLON real values to floor(NLON/2)+1 complex numbers. Hence we have
        ! to fill those floor(NLON/2)+1 values.
        ! Truncation happens starting at G_NMEN+1. Hence, we zero-fill those values.
        IF (JM <= G_NLOEN(IGLG)/2) THEN
          IOFF_LAT = KF_FS*D_NSTAGTF(KGL)
          IOFF_UV = IOFF_LAT+(KUV_OFFSET+JF-1)*(D_NSTAGTF(KGL+1)-D_NSTAGTF(KGL))
          IOFF_UV_EWDER = IOFF_LAT+(KUV_EWDER_OFFSET+JF-1)*(D_NSTAGTF(KGL+1)-D_NSTAGTF(KGL))

          RET_REAL = 0.0_JPRBT
          RET_COMPLEX = 0.0_JPRBT

          IF (JM <= G_NMEN(IGLG)) THEN
            ZACHTE2 = REAL(F_RACTHE(IGLG),JPRBT)

            RET_REAL = &
                & -PREEL_COMPLEX(IOFF_UV+2*JM+2)*ZACHTE2*REAL(JM,JPRBT)
            RET_COMPLEX =  &
                &  PREEL_COMPLEX(IOFF_UV+2*JM+1)*ZACHTE2*REAL(JM,JPRBT)
          ENDIF
          PREEL_COMPLEX(IOFF_UV_EWDER+2*JM+1) = RET_REAL
          PREEL_COMPLEX(IOFF_UV_EWDER+2*JM+2) = RET_COMPLEX
        ENDIF
      ENDDO
    ENDDO
  ENDDO
ENDIF

!*       2.2     SCALAR VARIABLES

IF (KSCALARS_EWDER_OFFSET > 0) THEN
#ifdef OMPGPU
  !$OMP TARGET TEAMS DISTRIBUTE PARALLEL DO DEFAULT(NONE) SHARED(KF_SCALARS,PEWDERS,ZACHTE2,PSCALAR)
#endif
#ifdef ACCGPU
  !$ACC PARALLEL LOOP COLLAPSE(3) DEFAULT(NONE) PRIVATE(IGLG,IOFF_LAT,IOFF_SCALARS_EWDER,IOFF_SCALARS,ZACHTE2,RET_REAL,RET_COMPLEX) &
  !$ACC& FIRSTPRIVATE(IBEG,IEND,IINC,KF_SCALARS,OFFSET_VAR,KSCALARS_EWDER_OFFSET,KSCALARS_OFFSET,KF_FS) ASYNC(1)
#endif
  DO KGL=IBEG,IEND,IINC
    DO JF=1,KF_SCALARS
      DO JM=0,G_NLOEN_MAX/2
        IGLG = OFFSET_VAR+KGL-1
        ! FFT transforms NLON real values to floor(NLON/2)+1 complex numbers. Hence we have
        ! to fill those floor(NLON/2)+1 values.
        ! Truncation happens starting at G_NMEN+1. Hence, we zero-fill those values.
        IF (JM <= G_NLOEN(IGLG)/2) THEN
          IOFF_LAT = KF_FS*D_NSTAGTF(KGL)
          IOFF_SCALARS_EWDER = IOFF_LAT+(KSCALARS_EWDER_OFFSET+JF-1)*(D_NSTAGTF(KGL+1)-D_NSTAGTF(KGL))
          IOFF_SCALARS = IOFF_LAT+(KSCALARS_OFFSET+JF-1)*(D_NSTAGTF(KGL+1)-D_NSTAGTF(KGL))

          RET_REAL = 0.0_JPRBT
          RET_COMPLEX = 0.0_JPRBT

          IF (JM <= G_NMEN(IGLG)) THEN
            ZACHTE2 = REAL(F_RACTHE(IGLG),JPRBT)

            RET_REAL = &
                & -PREEL_COMPLEX(IOFF_SCALARS+2*JM+2)*ZACHTE2*REAL(JM,JPRBT)
            RET_COMPLEX = &
                &  PREEL_COMPLEX(IOFF_SCALARS+2*JM+1)*ZACHTE2*REAL(JM,JPRBT)
          ENDIF
          ! The rest from G_NMEN(IGLG+1)...MAX is zero truncated
          PREEL_COMPLEX(IOFF_SCALARS_EWDER+2*JM+1) = RET_REAL
          PREEL_COMPLEX(IOFF_SCALARS_EWDER+2*JM+2) = RET_COMPLEX
        ENDIF
      ENDDO
    ENDDO
  ENDDO
ENDIF

#ifdef ACCGPU
!$ACC WAIT(1)

!$ACC END DATA
#endif
#ifdef OMPGPU
!$OMP END TARGET DATA
#endif
!     ------------------------------------------------------------------

END SUBROUTINE FSC
END MODULE FSC_MOD
