#define ALIGN(I, A) (((I)+(A)-1)/(A)*(A))
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

MODULE LEDIR_MOD
  USE PARKIND_ECTRANS,        ONLY: JPIM, JPRBT, JPRD
  USE BUFFERED_ALLOCATOR_MOD, ONLY: BUFFERED_ALLOCATOR
  IMPLICIT NONE

  PRIVATE
  PUBLIC :: LEDIR_STRIDES, LEDIR

  INTEGER(KIND=JPIM) :: A = 8 !Alignment
CONTAINS
  SUBROUTINE LEDIR_STRIDES(KF_FS,IOUT_STRIDES0,IOUT_SIZE,IIN_STRIDES0,IIN_SIZE,&
                           IOUT0_STRIDES0,IOUT0_SIZE,IIN0_STRIDES0,IIN0_SIZE)
    USE TPM_DIM,         ONLY: R
    USE TPM_DISTR,       ONLY: D, D_OFFSETS_GEMM1, D_OFFSETS_GEMM2

    IMPLICIT NONE

    INTEGER(KIND=JPIM), INTENT(IN)  :: KF_FS

    INTEGER(KIND=JPIM), OPTIONAL :: IOUT_STRIDES0, IOUT_SIZE
    INTEGER(KIND=JPIM), OPTIONAL :: IIN_STRIDES0, IIN_SIZE
    INTEGER(KIND=JPIM), OPTIONAL :: IOUT0_STRIDES0, IOUT0_SIZE
    INTEGER(KIND=JPIM), OPTIONAL :: IIN0_STRIDES0, IIN0_SIZE

    IF (PRESENT(IOUT_STRIDES0)) &
        IOUT_STRIDES0 = ALIGN(2*KF_FS,A)
    IF (PRESENT(IOUT_SIZE)) &
        IOUT_SIZE = IOUT_STRIDES0*D_OFFSETS_GEMM2(D%NUMP+1)
    IF (PRESENT(IIN_STRIDES0)) &
        IIN_STRIDES0 = ALIGN(2*KF_FS,A)
    IF (PRESENT(IIN_SIZE)) &
        IIN_SIZE = IIN_STRIDES0*D_OFFSETS_GEMM1(D%NUMP+1)
    IF (PRESENT(IOUT0_STRIDES0)) &
        IOUT0_STRIDES0 = ALIGN(KF_FS,A)
    IF (PRESENT(IOUT0_SIZE)) &
        IOUT0_SIZE = IOUT0_STRIDES0 * ALIGN(MAX((R%NTMAX+2)/2,(R%NTMAX+3)/2),A)
    IF (PRESENT(IIN0_STRIDES0)) &
        IIN0_STRIDES0 = ALIGN(KF_FS,A)
    IF (PRESENT(IIN0_SIZE)) &
        IIN0_SIZE = IIN0_STRIDES0 * ALIGN(R%NDGNH,A)
  END SUBROUTINE

  SUBROUTINE LEDIR(ALLOCATOR,ZINPS,ZINPA,ZINPS0,ZINPA0,ZOUT,ZOUT0,POA1,KF_FS)
    !**** *LEDIR* - Direct Legendre transform.

    !     Purpose.
    !     --------
    !        Direct Legendre tranform of state variables.

    !**   Interface.
    !     ----------
    !        CALL LEDIR(...)

    !        Explicit arguments :  KM - zonal wavenumber
    !        --------------------  KFC - number of field to transform
    !                              fields for zonal wavenumber KM
    !                              PSIA - symmetric part of Fourier
    !                              fields for zonal wavenumber KM
    !                              POA1 -  spectral
    !                              fields for zonal wavenumber KM

    !        Implicit arguments :  None.
    !        --------------------

    !     Method.
    !     -------   use butterfly or dgemm

    !     Externals.   
    !     ----------

    !     Reference.
    !     ----------
    !        ECMWF Research Department documentation of the IFS

    !     Author.
    !     -------
    !          Nils Wedi + Mats Hamrud + George Modzynski

    !     Modifications.
    !     --------------
    !        J.Hague : Oct 2012 DR_HOOK round calls to DGEMM:
    !      F. Vana  05-Mar-2015  Support for single precision
    !     ------------------------------------------------------------------

    USE TPM_GEN,                     ONLY: LSYNC_TRANS, NOUT
    USE YOMHOOK,                     ONLY: LHOOK,   DR_HOOK, JPHOOK
    USE TPM_DIM,                     ONLY: R_NDGNH,R_NSMAX,R_NTMAX,R_NDGL
    USE TPM_GEOMETRY,                ONLY: G_NDGLU
    USE TPM_FIELDS_FLAT,             ONLY: ZAA,ZAS,ZAA0,ZAS0,KMLOC0
    USE TPM_DISTR,                   ONLY: D_NUMP, D_MYMS, D_OFFSETS_GEMM1, D_OFFSETS_GEMM2
    USE HICBLAS_MOD,                 ONLY: HIP_DGEMM_BATCHED_OVERLOAD, &
      &                                    HIP_DGEMM_GROUPED_OVERLOAD, HIP_SGEMM_GROUPED_OVERLOAD
    USE MPL_MODULE,                  ONLY: MPL_BARRIER,MPL_ALL_MS_COMM
    USE TPM_STATS,                   ONLY: GSTATS => GSTATS_NVTX
    USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_INT

#ifdef TRANS_SINGLE
#define HIP_GEMM HIP_SGEMM_GROUPED_OVERLOAD
#else
#define HIP_GEMM HIP_DGEMM_GROUPED_OVERLOAD
#endif

    IMPLICIT NONE

    !     DUMMY ARGUMENTS
    REAL(KIND=JPRBT), INTENT(IN) :: ZINPS(:), ZINPA(:)
    REAL(KIND=JPRD), INTENT(IN) :: ZINPS0(:), ZINPA0(:)
    REAL(KIND=JPRBT), INTENT(INOUT) :: ZOUT(:)
    REAL(KIND=JPRD), INTENT(INOUT) ::  ZOUT0(:)
    REAL(KIND=JPRBT),  INTENT(OUT), POINTER :: POA1(:,:,:)
    INTEGER(KIND=JPIM), INTENT(IN)  :: KF_FS
    TYPE(BUFFERED_ALLOCATOR), INTENT(IN) :: ALLOCATOR

    !     LOCAL VARIABLES
    INTEGER(KIND=JPIM)  :: KM
    INTEGER(KIND=JPIM)  :: KMLOC
    INTEGER(KIND=JPIM) :: IA, IS, ISL, J
    INTEGER(KIND=JPIM)  :: KS(D_NUMP), NS(D_NUMP), AOFFSETS(D_NUMP), BOFFSETS(D_NUMP), COFFSETS(D_NUMP)
    REAL(KIND=JPHOOK) :: ZHOOK_HANDLE
    REAL(KIND=JPRBT) :: PAIA, PAIS, V1, V2

    INTEGER(KIND=JPIM) :: IGLS,  JF, JGL
    INTEGER(KIND=JPIM) :: OFFSET1, OFFSET2

    INTEGER(KIND=JPIM)  :: IOUT_STRIDES0, IOUT_STRIDES1
    INTEGER(KIND=JPIM)  :: IIN_STRIDES0, IIN_STRIDES1
    INTEGER(KIND=JPIM)  :: IOUT0_STRIDES0, IOUT0_STRIDES1
    INTEGER(KIND=JPIM)  :: IIN0_STRIDES0, IIN0_STRIDES1
    INTEGER(KIND=8)  :: ALLOC_SZ, ALLOC_POS

    IF (LHOOK) CALL DR_HOOK('LE_DGEMM',0,ZHOOK_HANDLE)

    CALL LEDIR_STRIDES(KF_FS,IOUT_STRIDES0,IOUT_STRIDES1,IIN_STRIDES0,IIN_STRIDES1,&
                       IOUT0_STRIDES0,IOUT0_STRIDES1,IIN0_STRIDES0,IIN0_STRIDES1)

#ifdef OMPGPU
#endif
#ifdef ACCGPU
    !$ACC DATA &
    !$ACC& PRESENT(ZINPS,ZINPA,ZOUT,ZINPS0,ZINPA0,ZOUT0) &
    !$ACC& PRESENT(D_MYMS,D_NUMP,R_NTMAX,R_NSMAX,G_NDGLU) &
    !$ACC& PRESENT(ZAA,ZAS,POA1,D_OFFSETS_GEMM1,D_OFFSETS_GEMM2)
#endif

    IF (LSYNC_TRANS) THEN
#ifdef ACCGPU
      !$ACC WAIT(1)
#endif
      CALL GSTATS(430,0)
      CALL MPL_BARRIER(MPL_ALL_MS_COMM,CDSTRING='')
      CALL GSTATS(430,1)
    ENDIF
    CALL GSTATS(414,0)

    IF(KMLOC0 > 0) THEN
      ! compute m=0 in double precision:
#ifdef OMPGPU
      !$OMP TARGET DATA USE_DEVICE_PTR(ZAA0,ZINPA0,ZOUT0)
#endif
#ifdef ACCGPU
      !$ACC HOST_DATA USE_DEVICE(ZAA0,ZINPA0,ZOUT0)
#endif
      CALL HIP_DGEMM_BATCHED_OVERLOAD( &
        & 'N', 'N', &
        & KF_FS, (R_NSMAX+2)/2, G_NDGLU(0), &
        & 1.0_JPRD, &
        & ZINPA0, IIN0_STRIDES0, 0, &
        & ZAA0, SIZE(ZAA0,1), 0, &
        & 0.0_JPRD, &
        & ZOUT0, IOUT0_STRIDES0, 0, &
        & 1, STREAM=1_C_INT, ALLOC=ALLOCATOR%PTR)
#ifdef OMPGPU
    !$OMP END TARGET DATA
#endif
#ifdef ACCGPU
    !$ACC END HOST_DATA
#endif
    ENDIF
    ! Get C in transpose format to get better memory access patterns later
    !C=A*B =>
    ! C^T=B^T*A^T
    DO KMLOC=1,D_NUMP
      KM = D_MYMS(KMLOC)
      NS(KMLOC) = (R_NSMAX-KM+2)/2
      KS(KMLOC) = G_NDGLU(KM)
      AOFFSETS(KMLOC) = IIN_STRIDES0*D_OFFSETS_GEMM1(KMLOC)
      BOFFSETS(KMLOC) = SIZE(ZAA,1)*SIZE(ZAA,2)*(KMLOC-1)
      COFFSETS(KMLOC) = IOUT_STRIDES0*D_OFFSETS_GEMM2(KMLOC)
    ENDDO
    IF(KMLOC0 > 0) THEN
      NS(KMLOC0) = 0
      KS(KMLOC0) = 0
    ENDIF
#ifdef OMPGPU
    !$OMP TARGET DATA USE_DEVICE_PTR(ZAA,ZINPA,ZOUT)
#endif
#ifdef ACCGPU
    !$ACC HOST_DATA USE_DEVICE(ZAA,ZINPA,ZOUT)
#endif
    CALL HIP_GEMM( &
      & 21, & ! unique identifier
      & 'N', 'N', &
      & 2*KF_FS, NS(:), KS(:), &
      & 1.0_JPRBT, &
      & ZINPA, IIN_STRIDES0, AOFFSETS, &
      & ZAA, SIZE(ZAA,1), BOFFSETS, &
      & 0.0_JPRBT, &
      & ZOUT, IOUT_STRIDES0, COFFSETS, &
      & D_NUMP, STREAM=1_C_INT, ALLOC=ALLOCATOR%PTR)
#ifdef OMPGPU
    !$OMP END TARGET DATA
#endif
#ifdef ACCGPU
    !$ACC END HOST_DATA
#endif
    IF (LSYNC_TRANS) THEN
#ifdef ACCGPU
      !$ACC WAIT(1)
#endif
      CALL GSTATS(434,0)
      CALL MPL_BARRIER(MPL_ALL_MS_COMM,CDSTRING='')
      CALL GSTATS(434,1)
    ENDIF
    CALL GSTATS(414,1)

#ifdef OMPGPU
#endif
#ifdef ACCGPU
    !$ACC PARALLEL LOOP COLLAPSE(2) PRIVATE(KM,IA,J) FIRSTPRIVATE(KF_FS,IOUT_STRIDES0,IOUT0_STRIDES0) DEFAULT(NONE) ASYNC(1)
#endif
    DO KMLOC=1,D_NUMP
      DO JF=1,2*KF_FS
        KM = D_MYMS(KMLOC)
        IA  = 1+MOD(R_NTMAX-KM+2,2)
        IF (KM /= 0) THEN
#ifdef OMPGPU
#endif
#ifdef ACCGPU
          !$ACC LOOP SEQ
#endif
          DO J=1,(R_NSMAX-KM+2)/2
            POA1(JF,IA+1+(J-1)*2,KMLOC) = ZOUT(JF+(J-1)*IOUT_STRIDES0+D_OFFSETS_GEMM2(KMLOC)*IOUT_STRIDES0)
          ENDDO
        ELSEIF (MOD(JF-1,2) == 0) THEN
#ifdef OMPGPU
#endif
#ifdef ACCGPU
          !$ACC LOOP SEQ
#endif
          DO J=1,(R_NSMAX+2)/2
            POA1(JF,IA+1+(J-1)*2,KMLOC) = ZOUT0((JF-1)/2+1+(J-1)*IOUT0_STRIDES0)
          ENDDO
        ENDIF
      ENDDO
    ENDDO

    ! symmetric

    IF (LSYNC_TRANS) THEN
#ifdef ACCGPU
      !$ACC WAIT(1)
#endif
      CALL GSTATS(430,0)
      CALL MPL_BARRIER(MPL_ALL_MS_COMM,CDSTRING='')
      CALL GSTATS(430,1)
    ENDIF
    CALL GSTATS(414,0)

    IF(KMLOC0 > 0) THEN
#ifdef OMPGPU
      !$OMP TARGET DATA USE_DEVICE_PTR(ZAS0,ZINPS0,ZOUT0)
#endif
#ifdef ACCGPU
      !$ACC HOST_DATA USE_DEVICE(ZAS0,ZINPS0,ZOUT0)
#endif
      ! compute m=0 in double precision:
      call HIP_DGEMM_BATCHED_OVERLOAD( &
        & 'N', 'N', &
        & KF_FS, (R_NSMAX+3)/2, G_NDGLU(0), &
        & 1.0_JPRD, &
        & ZINPS0, IIN0_STRIDES0, 0, &
        & ZAS0, SIZE(ZAS0,1), 0, &
        & 0.0_JPRD, &
        & ZOUT0, IOUT0_STRIDES0, 0, &
        & 1, STREAM=1_C_INT, ALLOC=ALLOCATOR%PTR)
#ifdef OMPGPU
    !$OMP END TARGET DATA
#endif
#ifdef ACCGPU
    !$ACC END HOST_DATA
#endif
    ENDIF

    ! Get C in transpose format to get better memory access patterns later
    !C=A*B =>
    ! C^T=B^T*A^T
    DO KMLOC=1,D_NUMP
      KM = D_MYMS(KMLOC)
      NS(KMLOC) = (R_NSMAX-KM+3)/2
      KS(KMLOC) = G_NDGLU(KM)
      AOFFSETS(KMLOC) = IIN_STRIDES0*D_OFFSETS_GEMM1(KMLOC)
      BOFFSETS(KMLOC) = SIZE(ZAS,1)*SIZE(ZAS,2)*(KMLOC-1)
      COFFSETS(KMLOC) = IOUT_STRIDES0*D_OFFSETS_GEMM2(KMLOC)
    ENDDO
    IF(KMLOC0 > 0) THEN
      NS(KMLOC0) = 0
      KS(KMLOC0) = 0
    ENDIF
#ifdef OMPGPU
    !$OMP TARGET DATA USE_DEVICE_PTR(ZAS,ZINPS,ZOUT)
#endif
#ifdef ACCGPU
    !$ACC HOST_DATA USE_DEVICE(ZAS,ZINPS,ZOUT)
#endif
    CALL HIP_GEMM( &
      & 22, & ! unique identifier
      & 'N', 'N', &
      & 2*KF_FS, NS(:), KS(:), &
      & 1.0_JPRBT, &
      & ZINPS, IIN_STRIDES0, AOFFSETS, &
      & ZAS, SIZE(ZAS,1), BOFFSETS, &
      & 0.0_JPRBT, &
      & ZOUT, IOUT_STRIDES0, COFFSETS, &
      & D_NUMP, STREAM=1_C_INT, ALLOC=ALLOCATOR%PTR)
#ifdef OMPGPU
    !$OMP END TARGET DATA
#endif
#ifdef ACCGPU
    !$ACC END HOST_DATA
#endif
    IF (LSYNC_TRANS) THEN
#ifdef ACCGPU
      !$ACC WAIT(1)
#endif
      CALL GSTATS(434,0)
      CALL MPL_BARRIER(MPL_ALL_MS_COMM,CDSTRING='')
      CALL GSTATS(434,1)
    ENDIF
    CALL GSTATS(414,1)

#ifdef OMPGPU
#endif
#ifdef ACCGPU
    !$ACC PARALLEL LOOP COLLAPSE(2) PRIVATE(KM,IS) FIRSTPRIVATE(KF_FS,IOUT_STRIDES0,IOUT0_STRIDES0) DEFAULT(NONE) ASYNC(1)
#endif
    DO KMLOC=1,D_NUMP
      DO JF=1,2*KF_FS
        KM = D_MYMS(KMLOC)
        IS  = 1+MOD(R_NTMAX-KM+1,2)
        IF (KM /= 0) THEN
#ifdef OMPGPU
#endif
#ifdef ACCGPU
          !$ACC LOOP SEQ
#endif
          DO J=1,(R_NSMAX-KM+3)/2
            POA1(JF,IS+1+(J-1)*2,KMLOC) = ZOUT(JF+(J-1)*IOUT_STRIDES0+D_OFFSETS_GEMM2(KMLOC)*IOUT_STRIDES0)
          ENDDO
        ELSEIF (MOD(JF-1,2) == 0) THEN
#ifdef OMPGPU
#endif
#ifdef ACCGPU
          !$ACC LOOP SEQ
#endif
          DO J=1,(R_NSMAX+3)/2
            POA1(JF,IS+1+(J-1)*2,KMLOC) = ZOUT0((JF-1)/2+1+(J-1)*IOUT0_STRIDES0)
          ENDDO
        ENDIF
      ENDDO
    ENDDO
#ifdef OMPGPU
#endif
#ifdef ACCGPU
    !$ACC WAIT(1)

    !$ACC END DATA
#endif

    IF (LHOOK) CALL DR_HOOK('LE_DGEMM',1,ZHOOK_HANDLE)
    !     ------------------------------------------------------------------
  END SUBROUTINE LEDIR
END MODULE LEDIR_MOD
