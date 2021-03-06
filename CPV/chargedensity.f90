!
! Copyright (C) 2002-2009 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!

!  ----------------------------------------------
!  AB INITIO COSTANT PRESSURE MOLECULAR DYNAMICS
!  ----------------------------------------------




!=----------------------------------------------------------------------=!
    FUNCTION dft_total_charge_x( c, ngw, fi, n )
!=----------------------------------------------------------------------=!
       !
       !  This subroutine compute the Total Charge in reciprocal space
       !

       USE kinds,              ONLY: DP
       USE reciprocal_vectors, ONLY: gzero

       IMPLICIT NONE

       INTEGER,     INTENT(IN) :: ngw, n
       COMPLEX(DP), INTENT(IN) :: c(:,:)
       REAL (DP),   INTENT(IN) :: fi(:)
       !
       REAL(DP) :: dft_total_charge_x
       !
       INTEGER     :: ib, igs
       REAL(DP)    :: rsum
       COMPLEX(DP) :: wdot
       COMPLEX(DP) :: zdotc
       EXTERNAL zdotc

        rsum = 0.0d0

        IF( gzero ) THEN

          DO ib = 1, n
            wdot = zdotc( ( ngw - 1 ), c(2,ib), 1, c(2,ib), 1 )
            wdot = wdot + DBLE( c(1,ib) )**2 / 2.0d0
            rsum = rsum + fi(ib) * DBLE( wdot )
          END DO

        ELSE

          DO ib = 1, n
            wdot = zdotc( ngw, c(1,ib), 1, c(1,ib), 1 )
            rsum = rsum + fi(ib) * DBLE( wdot )
          END DO

        END IF

        dft_total_charge_x = rsum

        RETURN
      END FUNCTION dft_total_charge_x



!-----------------------------------------------------------------------
   SUBROUTINE rhoofr_cp &
      ( nfi, c, irb, eigrb, bec, rhovan, rhor, rhog, rhos, enl, denl, ekin, dekin, tstress, ndwwf )
!-----------------------------------------------------------------------
!
!  this routine computes:
!  rhor  = normalized electron density in real space
!  ekin  = kinetic energy
!  dekin = kinetic energy term of QM stress
!
!    rhor(r) = (sum over ib) fi(ib) |psi(r,ib)|^2
!
!    Using quantities in scaled space
!    rhor(r) = rhor(s) / Omega
!    rhor(s) = (sum over ib) fi(ib) |psi(s,ib)|^2 
!
!    fi(ib) = occupation numbers
!    psi(r,ib) = psi(s,ib) / SQRT( Omega ) 
!    psi(s,ib) = INV_FFT (  c0(ig,ib)  )
!
!    ib = index of band
!    ig = index of G vector
!  ----------------------------------------------
!     the normalized electron density rhor in real space
!     the kinetic energy ekin
!     subroutine uses complex fft so it computes two ft's
!     simultaneously
!
!     rho_i,ij = sum_n < beta_i,i | psi_n >< psi_n | beta_i,j >
!     < psi_n | beta_i,i > = c_n(0) beta_i,i(0) +
!                   2 sum_g> re(c_n*(g) (-i)**l beta_i,i(g) e^-ig.r_i)
!
!     e_v = sum_i,ij rho_i,ij d^ion_is,ji
!
      USE kinds,              ONLY: DP
      USE control_flags,      ONLY: iprint, iprsta, thdyn, tpre, trhor
      USE ions_base,          ONLY: nat
      USE gvecp,              ONLY: ngm
      USE gvecs,              ONLY: ngs, nps, nms
      USE gvecb,              ONLY: ngb
      USE gvecw,              ONLY: ngw
      USE recvecs_indexes,    ONLY: np, nm
      USE reciprocal_vectors, ONLY: gstart
      USE uspp,               ONLY: nkb
      USE uspp_param,         ONLY: nh, nhm
      USE grid_dimensions,    ONLY: nr1, nr2, nr3, &
                                    nr1x, nr2x, nr3x, nrxx
      USE cell_base,          ONLY: omega
      USE smooth_grid_dimensions, ONLY: nrxxs
      USE electrons_base,     ONLY: nx => nbspx, n => nbsp, f, ispin, nspin
      USE constants,          ONLY: pi, fpi
      USE mp,                 ONLY: mp_sum
      USE io_global,          ONLY: stdout, ionode
      USE mp_global,          ONLY: intra_image_comm, nogrp, me_image, &
                                    use_task_groups, ogrp_comm, nolist
      USE funct,              ONLY: dft_is_meta
      USE cg_module,          ONLY: tcg
      USE cp_interfaces,      ONLY: stress_kin
      USE fft_interfaces,     ONLY: fwfft, invfft
      USE fft_base,           ONLY: dffts, dfftp
      USE cp_interfaces,      ONLY: checkrho
      USE cdvan,              ONLY: dbec, drhovan
      USE cp_main_variables,  ONLY: iprint_stdout, drhor, drhog
      USE wannier_base,       ONLY: iwf
      USE cell_base,          ONLY: a1, a2, a3
!
      IMPLICIT NONE
      INTEGER nfi
      REAL(DP) bec(:,:)
      REAL(DP) rhovan(:, :, : )
      REAL(DP) rhor(:,:)
      REAL(DP) rhos(:,:)
      REAL(DP) enl, ekin
      REAL(DP) denl(3,3), dekin(6)
      COMPLEX(DP) eigrb( :, : )
      COMPLEX(DP) rhog( :, : )
      COMPLEX(DP) c( :, : )
      INTEGER irb( :, : )
      LOGICAL, OPTIONAL, INTENT(IN) :: tstress
      INTEGER, OPTIONAL, INTENT(IN) :: ndwwf

      ! local variables

      INTEGER  :: iss, isup, isdw, iss1, iss2, ios, i, ir, ig, k
      REAL(DP) :: rsumr(2), rsumg(2), sa1, sa2, detmp(6), mtmp(3,3)
      REAL(DP) :: rnegsum, rmin, rmax, rsum
      REAL(DP), EXTERNAL :: enkin, ennl
      COMPLEX(DP) :: ci,fp,fm
      COMPLEX(DP), ALLOCATABLE :: psi(:), psis(:)

      LOGICAL, SAVE :: first = .TRUE.
      LOGICAL :: ttstress
      
      !

      CALL start_clock( 'rhoofr' )

      ttstress = tpre
      IF( PRESENT( tstress ) ) ttstress = tstress

      ci = ( 0.0d0, 1.0d0 )

      rhor = 0.d0
      rhos = 0.d0
      rhog = (0.d0, 0.d0)
      !
      !  calculation of kinetic energy ekin
      !
      ekin = enkin( c, ngw, f, n )
      !
      IF( ttstress ) THEN
         !
         ! ... compute kinetic energy contribution
         !
         CALL stress_kin( dekin, c, f )
         !
      END IF

      IF( PRESENT( ndwwf ) ) THEN
         !
         !     called from WF, compute only of rhovan
         !
         CALL calrhovan( rhovan, bec, iwf )
         !
      ELSE
         !
         !     calculation of non-local energy
         !
         enl = ennl( rhovan, bec )
         !
      END IF
      !
      IF( ttstress ) THEN
         !
         IF( .NOT. ALLOCATED( drhovan ) ) &
            CALL errore( ' rhoofr ', ' drhovan not allocated ', 1 )
         !
         CALL dennl( bec, dbec, drhovan, denl ) 
         !
      END IF
      !    
      !    warning! trhor and thdyn are not compatible yet!   
      !
      COMPUTE_CHARGE: IF( trhor .AND. ( .NOT. thdyn ) ) THEN
         !
         !   non self-consistent calculation  
         !   charge density is read from unit 47
         !
         CALL read_rho( nspin, rhor )

         ALLOCATE( psi( nrxx ) )
!
         IF(nspin.EQ.1)THEN
            iss=1
            DO ir=1,nrxx
               psi(ir)=CMPLX(rhor(ir,iss),0.d0,kind=DP)
            END DO
            CALL fwfft('Dense', psi, dfftp )
            DO ig=1,ngm
               rhog(ig,iss)=psi(np(ig))
            END DO
         ELSE
            isup=1
            isdw=2
            DO ir=1,nrxx
               psi(ir)=CMPLX(rhor(ir,isup),rhor(ir,isdw),kind=DP)
            END DO
            CALL fwfft('Dense', psi, dfftp )
            DO ig=1,ngm
               fp=psi(np(ig))+psi(nm(ig))
               fm=psi(np(ig))-psi(nm(ig))
               rhog(ig,isup)=0.5d0*CMPLX( DBLE(fp),AIMAG(fm),kind=DP)
               rhog(ig,isdw)=0.5d0*CMPLX(AIMAG(fp),-DBLE(fm),kind=DP)
            END DO
         ENDIF

         DEALLOCATE( psi )
!
      ELSE
         !     ==================================================================
         !     self-consistent charge
         !     ==================================================================
         !
         !     important: if n is odd then nx must be .ge.n+1 and c(*,n+1)=0.
         ! 

         IF ( MOD( n, 2 ) /= 0 ) THEN
            !
            IF( SIZE( c, 2 ) < n+1 ) &
               CALL errore( ' rhoofr ', ' c second dimension too small ', SIZE( c, 2 ) )
            !
            c( :, n+1 ) = ( 0.d0, 0.d0 )
            !
         ENDIF
         !
         IF( PRESENT( ndwwf ) ) THEN
            !
            ! Wannier function, charge density from state iwf
            !
            i = iwf
            !
            psis = 0.D0
            DO ig=1,ngw
               psis(nms(ig))=CONJG(c(ig,i))
               psis(nps(ig))=c(ig,i)
            END DO
            !
            CALL invfft('Wave',psis, dffts )
            !
            iss1=1
            sa1=f(i)/omega
            DO ir=1,nrxxs
               rhos(ir,iss1)=rhos(ir,iss1) + sa1*( DBLE(psis(ir)))**2
            END DO
            !
         ELSE IF( use_task_groups ) THEN
            !
            CALL loop_over_states_tg()
            !
         ELSE
            !
            ALLOCATE( psis( nrxxs ) ) 
            !
            DO i = 1, n, 2
               !
               CALL c2psi( psis, nrxxs, c( 1, i ), c( 1, i+1 ), ngw, 2 )

               CALL invfft('Wave',psis, dffts )
               !
               iss1 = ispin(i)
               sa1  = f(i) / omega
               IF ( i .NE. n ) THEN
                  iss2 = ispin(i+1)
                  sa2  = f(i+1) / omega
               ELSE
                  iss2 = iss1
                  sa2  = 0.0d0
               END IF
               !
               DO ir = 1, nrxxs
                  rhos(ir,iss1) = rhos(ir,iss1) + sa1 * ( DBLE(psis(ir)))**2
                  rhos(ir,iss2) = rhos(ir,iss2) + sa2 * (AIMAG(psis(ir)))**2
               END DO
               !
            END DO
            !
            DEALLOCATE( psis ) 
            !
         END IF
         !
         !     smooth charge in g-space is put into rhog(ig)
         !
         ALLOCATE( psis( nrxxs ) ) 
         !
         IF(nspin.EQ.1)THEN
            iss=1
            DO ir=1,nrxxs
               psis(ir)=CMPLX(rhos(ir,iss),0.d0,kind=DP)
            END DO
            CALL fwfft('Smooth', psis, dffts )
            DO ig=1,ngs
               rhog(ig,iss)=psis(nps(ig))
            END DO
         ELSE
            isup=1
            isdw=2
             DO ir=1,nrxxs
               psis(ir)=CMPLX(rhos(ir,isup),rhos(ir,isdw),kind=DP)
            END DO
            CALL fwfft('Smooth',psis, dffts )
            DO ig=1,ngs
               fp= psis(nps(ig)) + psis(nms(ig))
               fm= psis(nps(ig)) - psis(nms(ig))
               rhog(ig,isup)=0.5d0*CMPLX( DBLE(fp),AIMAG(fm),kind=DP)
               rhog(ig,isdw)=0.5d0*CMPLX(AIMAG(fp),-DBLE(fm),kind=DP)
            END DO
         ENDIF
         !
         ALLOCATE( psi( nrxx ) )
         !
         IF( nspin .EQ. 1 ) THEN
            ! 
            !     case nspin=1
            ! 
            iss=1
            psi (:) = (0.d0, 0.d0)
            DO ig=1,ngs
               psi(nm(ig))=CONJG(rhog(ig,iss))
               psi(np(ig))=      rhog(ig,iss)
            END DO
            CALL invfft('Dense',psi, dfftp )
            DO ir=1,nrxx
               rhor(ir,iss)=DBLE(psi(ir))
            END DO
            !
         ELSE 
            !
            !     case nspin=2
            !
            isup=1
            isdw=2
            psi (:) = (0.d0, 0.d0)
            DO ig=1,ngs
               psi(nm(ig))=CONJG(rhog(ig,isup))+ci*CONJG(rhog(ig,isdw))
               psi(np(ig))=rhog(ig,isup)+ci*rhog(ig,isdw)
            END DO
            CALL invfft('Dense',psi, dfftp )
            DO ir=1,nrxx
               rhor(ir,isup)= DBLE(psi(ir))
               rhor(ir,isdw)=AIMAG(psi(ir))
            END DO
         ENDIF
         !
         IF ( dft_is_meta() ) CALL kedtauofr_meta( c, psi, SIZE( psi ), psis, SIZE( psis ) ) ! METAGGA
         !
         DEALLOCATE( psi ) 
         DEALLOCATE( psis ) 
         !
         !     add vanderbilt contribution to the charge density
         !     drhov called before rhov because input rho must be the smooth part
         !
         IF ( ttstress ) &
            CALL drhov( irb, eigrb, rhovan, drhovan, rhog, rhor, drhog, drhor )
         !
         CALL rhov( irb, eigrb, rhovan, rhog, rhor )

      ENDIF COMPUTE_CHARGE
!
      IF( PRESENT( ndwwf ) ) THEN
         !
         CALL old_write_rho( ndwwf, nspin, rhor, a1, a2, a3 )
         !
      END IF
!
!     here to check the integral of the charge density
!
      IF( ( iprsta > 2 ) .OR. ( nfi == 0 ) .OR. &
          ( MOD(nfi, iprint_stdout) == 0 ) .AND. ( .NOT. tcg ) ) THEN

         IF( iprsta > 2 ) THEN
            CALL checkrho( nrxx, nspin, rhor, rmin, rmax, rsum, rnegsum )
            rnegsum = rnegsum * omega / DBLE(nr1*nr2*nr3)
            rsum    = rsum    * omega / DBLE(nr1*nr2*nr3)
            WRITE( stdout,'(a,4(1x,f12.6))')                                     &
     &     ' rhoofr: rmin rmax rnegsum rsum  ',rmin,rmax,rnegsum,rsum
         END IF

         CALL sum_charge( rsumg, rsumr )

         IF ( nspin == 1 ) THEN
           WRITE( stdout, 10) rsumg(1), rsumr(1)
         ELSE
           WRITE( stdout, 20) rsumg(1), rsumr(1), rsumg(2), rsumr(2)
         ENDIF

      ENDIF

10    FORMAT( /, 3X, 'from rhoofr: total integrated electronic density', &
            & /, 3X, 'in g-space = ', f11.6, 3x, 'in r-space =', f11.6 )
20    FORMAT( /, 3X, 'from rhoofr: total integrated electronic density', &
            & /, 3X, 'spin up', &
            & /, 3X, 'in g-space = ', f11.6, 3x, 'in r-space =', f11.6 , &
            & /, 3X, 'spin down', &
            & /, 3X, 'in g-space = ', f11.6, 3x, 'in r-space =', f11.6 )
!
      CALL stop_clock( 'rhoofr' )

!
      RETURN


   CONTAINS   
      !
      !
      SUBROUTINE sum_charge( rsumg, rsumr )
         !
         REAL(DP), INTENT(OUT) :: rsumg( : )
         REAL(DP), INTENT(OUT) :: rsumr( : )
         INTEGER :: iss
         !
         DO iss=1,nspin
            rsumg(iss)=omega*DBLE(rhog(1,iss))
            rsumr(iss)=SUM(rhor(:,iss),1)*omega/DBLE(nr1*nr2*nr3)
         END DO

         IF (gstart.NE.2) THEN
            ! in the parallel case, only one processor has G=0 !
            DO iss=1,nspin
               rsumg(iss)=0.0d0
            END DO
         END IF

         CALL mp_sum( rsumg( 1:nspin ), intra_image_comm )
         CALL mp_sum( rsumr( 1:nspin ), intra_image_comm )

         RETURN
      END SUBROUTINE

      !
      !

      SUBROUTINE loop_over_states_tg
         !
         USE parallel_include
         !
         !        MAIN LOOP OVER THE EIGENSTATES
         !           - This loop is also parallelized within the task-groups framework
         !           - Each group works on a number of eigenstates in parallel
         !
         IMPLICIT NONE
         !
         INTEGER :: from, ii, eig_index, eig_offset
         REAL(DP), ALLOCATABLE :: tmp_rhos(:,:)

         ALLOCATE( psis( dffts%tg_nnr * nogrp ) ) 
         !
         ALLOCATE( tmp_rhos ( dffts%nr1x*dffts%nr2x*dffts%tg_npp( me_image + 1 ), nspin ) )
         !
         tmp_rhos = 0_DP

         do i = 1, n, 2*nogrp
            !
            !  Initialize wave-functions in Fourier space (to be FFTed)
            !  The size of psis is nnr: which is equal to the total number
            !  of local fourier coefficients.
            !
!$omp parallel default(shared), private(eig_offset, ig, eig_index )
            !
!$omp do
            do ig = 1, SIZE(psis)
               psis (ig) = (0.d0, 0.d0)
            end do
            !
            !  Loop for all local g-vectors (ngw)
            !  c: stores the Fourier expansion coefficients
            !     the i-th column of c corresponds to the i-th state
            !  nms and nps matrices: hold conversion indices form 3D to
            !     1-D vectors. Columns along the z-direction are stored contigiously
            !
            !  The outer loop goes through i : i + 2*NOGRP to cover
            !  2*NOGRP eigenstates at each iteration
            !
            eig_offset = 0

            do eig_index = 1, 2*nogrp, 2   
               !
               !  here we pack 2*nogrp electronic states in the psis array
               !
               IF ( ( i + eig_index - 1 ) <= n ) THEN
                  !
                  !  Outer loop for eigenvalues
                  !  The  eig_index loop is executed only ONCE when NOGRP=1.
                  !  Equivalent to the case with no task-groups
                  !  dfft%nsw(me) holds the number of z-sticks for the current processor per wave-function
                  !  We can either send these in the group with an mpi_allgather...or put the
                  !  in the PSIS vector (in special positions) and send them with them.
                  !  Otherwise we can do this once at the beginning, before the loop.
                  !  we choose to do the latter one.

!$omp do
                  do ig=1,ngw
                     psis(nms(ig)+eig_offset*dffts%tg_nnr)=conjg(c(ig,i+eig_index-1))+ci*conjg(c(ig,i+eig_index))
                     psis(nps(ig)+eig_offset*dffts%tg_nnr)=c(ig,i+eig_index-1)+ci*c(ig,i+eig_index)
                  end do
                  !
                  eig_offset = eig_offset + 1
                  !
               ENDIF
               !
            end do
!$omp end parallel

            !  2*NOGRP are trasformed at the same time
            !  psis: holds the fourier coefficients of the current proccesor
            !        for eigenstates i and i+2*NOGRP-1
            !
            CALL invfft( 'Wave', psis, dffts )
            !
            ! Now the first proc of the group holds the first two bands
            ! of the 2*nogrp bands that we are processing at the same time,
            ! the second proc. holds the third and fourth band
            ! and so on
            !
            ! Compute the proper factor for each band
            !
            DO ii = 1, nogrp
               IF( nolist( ii ) == me_image ) EXIT
            END DO
            !
            ! Remember two bands are packed in a single array :
            ! proc 0 has bands ibnd   and ibnd+1
            ! proc 1 has bands ibnd+2 and ibnd+3
            ! ....
            !
            ii = 2 * ii - 1

            IF( ii + i - 1 < n ) THEN
               iss1=ispin( ii + i - 1 )
               sa1 =f( ii + i - 1 )/omega
               iss2=ispin( ii + i )
               sa2 =f( ii + i )/omega
            ELSE IF( ii + i - 1 == n ) THEN
               iss1=ispin( ii + i - 1 )
               sa1 =f( ii + i - 1 )/omega
               iss2=iss1
               sa2=0.0d0
            ELSE
               iss1=ispin( n )
               sa1 = 0.0d0
               iss2=iss1
               sa2 =0.0d0
            END IF
            !
            !Compute local charge density
            !
            !This is the density within each orbital group...so it
            !coresponds to 1 eignestate for each group and there are
            !NOGRP such groups. Thus, during the loop across all
            !occupied eigenstates, the total charge density must me
            !accumulated across all different orbital groups.
            !

            !This loop goes through all components of charge density that is local
            !to each processor. In the original code this is nrxxs. In the task-groups
            !code this should be equal to the total number of planes
            !

            ir =  dffts%nr1x*dffts%nr2x*dffts%tg_npp( me_image + 1 ) 
            IF( ir > SIZE( psis ) ) &
               CALL errore( ' rhoofr ', ' psis size too small ', ir )

!$omp parallel do default(shared)
            do ir = 1, dffts%nr1x*dffts%nr2x*dffts%tg_npp( me_image + 1 )
               tmp_rhos(ir,iss1) = tmp_rhos(ir,iss1) + sa1*( real(psis(ir)))**2
               tmp_rhos(ir,iss2) = tmp_rhos(ir,iss2) + sa2*(aimag(psis(ir)))**2
            end do
            !
         END DO

         IF ( nogrp > 1 ) THEN
            CALL mp_sum( tmp_rhos, gid = ogrp_comm )
         ENDIF
         !
         !BRING CHARGE DENSITY BACK TO ITS ORIGINAL POSITION
         !
         !If the current processor is not the "first" processor in its
         !orbital group then does a local copy (reshuffling) of its data
         !
         from = 1
         DO ii = 1, nogrp
            IF ( nolist( ii ) == me_image ) EXIT !Exit the loop
            from = from +  dffts%nr1x*dffts%nr2x*dffts%npp( nolist( ii ) + 1 )! From where to copy initially
         ENDDO
         !
         DO ir = 1, nspin
            CALL dcopy( dffts%nr1x*dffts%nr2x*dffts%npp(me_image+1), tmp_rhos(from,ir), 1, rhos(1,ir), 1)
         ENDDO

         DEALLOCATE( tmp_rhos )
         DEALLOCATE( psis ) 

         RETURN
      END SUBROUTINE loop_over_states_tg

!-----------------------------------------------------------------------
   END SUBROUTINE rhoofr_cp
!-----------------------------------------------------------------------



!=----------------------------------------------------------------------=!
   SUBROUTINE fillgrad_x( nspin, rhog, gradr )
!=----------------------------------------------------------------------=!

      !
      !     calculates gradient of charge density for gradient corrections
      !     in: charge density on G-space    out: gradient in R-space
      !
      USE kinds,              ONLY: DP
      use reciprocal_vectors, only: gx
      use recvecs_indexes,    only: np, nm
      use gvecp,              only: ngm
      use grid_dimensions,    only: nr1, nr2, nr3, &
                                    nr1x, nr2x, nr3x, nrxx
      use cell_base,          only: tpiba
      USE fft_interfaces,     ONLY: invfft
      USE fft_base,           ONLY: dfftp
!
      implicit none
! input
      integer, intent(in) :: nspin
      complex(DP) :: rhog( ngm, nspin )
! output
      real(DP) ::    gradr( nrxx, 3, nspin )
! local
      complex(DP), allocatable :: v(:)
      complex(DP) :: ci
      integer     :: iss, ig, ir
!
!
      allocate( v( nrxx ) ) 
      !
      ci = ( 0.0d0, 1.0d0 )
      do iss = 1, nspin
!$omp parallel default(shared), private(ig)
!$omp do
         do ig = 1, nrxx
            v( ig ) = ( 0.0d0, 0.0d0 )
         end do
!$omp do
         do ig=1,ngm
            v(np(ig))=      ci*tpiba*gx(1,ig)*rhog(ig,iss)
            v(nm(ig))=CONJG(ci*tpiba*gx(1,ig)*rhog(ig,iss))
         end do
!$omp end parallel
         !
         call invfft( 'Dense', v, dfftp )
         !
!$omp parallel default(shared), private(ig,ir)
!$omp do
         do ir=1,nrxx
            gradr(ir,1,iss)=DBLE(v(ir))
         end do
!$omp do
         do ig=1,nrxx
            v(ig)=(0.0d0,0.0d0)
         end do
!$omp do
         do ig=1,ngm
            v(np(ig))= tpiba*(      ci*gx(2,ig)*rhog(ig,iss)-           &
     &                                 gx(3,ig)*rhog(ig,iss) )
            v(nm(ig))= tpiba*(CONJG(ci*gx(2,ig)*rhog(ig,iss)+           &
     &                                 gx(3,ig)*rhog(ig,iss)))
         end do
!$omp end parallel
         !
         call invfft( 'Dense', v, dfftp )
         !
!$omp parallel do default(shared)
         do ir=1,nrxx
            gradr(ir,2,iss)= DBLE(v(ir))
            gradr(ir,3,iss)=AIMAG(v(ir))
         end do
      end do
      !
      deallocate( v )
!
      RETURN
    END SUBROUTINE fillgrad_x


!
!----------------------------------------------------------------------
   SUBROUTINE checkrho_x(nnr,nspin,rhor,rmin,rmax,rsum,rnegsum)
!----------------------------------------------------------------------
!
!     check \int rho(r)dr and the negative part of rho
!
      USE kinds,     ONLY: DP
      USE mp,        ONLY: mp_sum
      USE mp_global, ONLY: intra_image_comm

      IMPLICIT NONE

      INTEGER, INTENT(IN) :: nnr, nspin
      REAL(DP) rhor(nnr,nspin), rmin, rmax, rsum, rnegsum
      !
      REAL(DP) roe
      INTEGER ir, iss
!
      rsum   =0.0d0
      rnegsum=0.0d0
      rmin   =100.d0
      rmax   =0.0d0 
      DO iss = 1, nspin
         DO ir = 1, nnr
            roe  = rhor(ir,iss)
            rsum = rsum + roe
            IF ( roe < 0.0d0 ) rnegsum = rnegsum + roe
            rmax = MAX( rmax, roe )
            rmin = MIN( rmin, roe )
         END DO
      END DO
      CALL mp_sum( rsum, intra_image_comm )
      CALL mp_sum( rnegsum, intra_image_comm )
      RETURN
   END SUBROUTINE checkrho_x


!-----------------------------------------------------------------------
SUBROUTINE drhov(irb,eigrb,rhovan,drhovan,rhog,rhor,drhog,drhor)
!-----------------------------------------------------------------------
!     this routine calculates arrays drhog drhor, derivatives wrt h of:
!
!        n_v(g) = sum_i,ij rho_i,ij q_i,ji(g) e^-ig.r_i
!
!     Same logic as in routine rhov.
!     On input rhor and rhog must contain the smooth part only !!!
!     Output in (drhor, drhog)
!
      USE kinds,                    ONLY: DP
      USE control_flags,            ONLY: iprint
      USE ions_base,                ONLY: na, nsp, nat
      USE cvan,                     ONLY: nvb
      USE uspp_param,               ONLY: nhm, nh
      USE grid_dimensions,          ONLY: nr1, nr2, nr3, nr1x, nr2x, nr3x, nnr => nrxx
      USE electrons_base,           ONLY: nspin
      USE gvecb,                    ONLY: ngb, npb, nmb
      USE gvecp,                    ONLY: ng => ngm
      USE smallbox_grid_dimensions, ONLY: nr1b, nr2b, nr3b, nr1bx, nr2bx, nr3bx, nnrb => nnrbx
      USE cell_base,                ONLY: ainv
      USE qgb_mod,                  ONLY: qgb
      USE dqgb_mod,                 ONLY: dqgb
      USE recvecs_indexes,          ONLY: nm, np
      USE fft_interfaces,           ONLY: fwfft, invfft
      USE fft_base,                 ONLY: dfftb, dfftp

      IMPLICIT NONE
! input
      INTEGER,     INTENT(IN) ::  irb(3,nat)
      REAL(DP),    INTENT(IN) ::  rhor(nnr,nspin)
      REAL(DP),    INTENT(IN) ::  rhovan(nhm*(nhm+1)/2,nat,nspin)
      REAL(DP),    INTENT(IN) ::  drhovan(nhm*(nhm+1)/2,nat,nspin,3,3)
      COMPLEX(DP), INTENT(IN) ::  eigrb(ngb,nat), rhog(ng,nspin)
! output
      REAL(DP),    INTENT(OUT) :: drhor(nnr,nspin,3,3)
      COMPLEX(DP), INTENT(OUT) :: drhog(ng,nspin,3,3)
! local
      INTEGER i, j, isup, isdw, nfft, ifft, iv, jv, ig, ijv, is, iss,   &
     &     isa, ia, ir
      REAL(DP) :: asumt, dsumt
      COMPLEX(DP) fp, fm, ci
      COMPLEX(DP), ALLOCATABLE :: v(:)
      COMPLEX(DP), ALLOCATABLE:: dqgbt(:,:)
      COMPLEX(DP), ALLOCATABLE :: qv(:)
!
#ifdef __OPENMP
      INTEGER  :: itid, mytid, ntids
      INTEGER  :: omp_get_thread_num, omp_get_num_threads
      EXTERNAL :: omp_get_thread_num, omp_get_num_threads
#endif
!
      DO j=1,3
         DO i=1,3
            DO iss=1,nspin
               DO ir=1,nnr
                  drhor(ir,iss,i,j)=-rhor(ir,iss)*ainv(j,i)
               END DO
               DO ig=1,ng
                  drhog(ig,iss,i,j)=-rhog(ig,iss)*ainv(j,i)
               END DO
            END DO
         END DO
      END DO

      IF ( nvb < 0 ) RETURN

      ALLOCATE( v( nnr ) )

      ci =( 0.0d0, 1.0d0 )

      IF( nspin == 1 ) THEN
         !  
         !  nspin=1 : two fft at a time, one per atom, if possible
         ! 
         DO i=1,3
            DO j=1,3

               v(:) = (0.d0, 0.d0)

!$omp parallel default(none) &
!$omp          shared(nvb, na, nnrb, ngb, nh, eigrb, dfftb, irb, v, &
!$omp                 nmb, ci, npb, i, j, dqgb, qgb, nhm, rhovan, drhovan ) &
!$omp          private(mytid, ntids, is, ia, nfft, ifft, iv, jv, ijv, ig, iss, isa, &
!$omp                  qv, itid, dqgbt, dsumt, asumt )

               ALLOCATE( qv( nnrb ) )
               ALLOCATE( dqgbt( ngb, 2 ) )

#ifdef __OPENMP
               mytid = omp_get_thread_num()  ! take the thread ID
               ntids = omp_get_num_threads() ! take the number of threads
               itid  = 0
#endif

               iss=1
               isa=1

               DO is=1,nvb
#ifdef __PARA
                  DO ia=1,na(is)
                     nfft=1
                     IF ( dfftb%np3( isa ) <= 0 ) then
                        isa = isa + nfft
                        CYCLE
                     END IF
#else
                  DO ia=1,na(is),2
                     !
                     !  nfft=2 if two ffts at the same time are performed
                     !
                     nfft=2
                     IF (ia.EQ.na(is)) nfft=1
#endif

#ifdef __OPENMP
                     IF ( mytid /= itid ) THEN
                        isa = isa + nfft
                        itid = MOD( itid + 1, ntids )
                        CYCLE
                     ELSE
                        itid = MOD( itid + 1, ntids )
                     END IF
#endif

                     dqgbt(:,:) = (0.d0, 0.d0) 
                     qv(:) = (0.d0, 0.d0)
                     DO ifft=1,nfft
                        DO iv=1,nh(is)
                           DO jv=iv,nh(is)
                              ijv = (jv-1)*jv/2 + iv
                              IF(iv.NE.jv) THEN
                                 asumt = 2.0d0 *  rhovan( ijv, isa+ifft-1, iss )
                                 dsumt = 2.0d0 * drhovan( ijv, isa+ifft-1, iss, i, j )
                              ELSE
                                 asumt =  rhovan( ijv, isa+ifft-1, iss )
                                 dsumt = drhovan( ijv, isa+ifft-1, iss, i, j )
                              ENDIF
                              DO ig=1,ngb
                                 dqgbt(ig,ifft)=dqgbt(ig,ifft) + asumt*dqgb(ig,ijv,is,i,j)
                                 dqgbt(ig,ifft)=dqgbt(ig,ifft) + dsumt*qgb(ig,ijv,is)
                              END DO
                           END DO
                        END DO
                     END DO
                     !     
                     ! add structure factor
                     !
                     IF(nfft.EQ.2) THEN
                        DO ig=1,ngb
                           qv(npb(ig)) = eigrb(ig,isa   )*dqgbt(ig,1)  &
     &                        + ci*      eigrb(ig,isa+1 )*dqgbt(ig,2)
                           qv(nmb(ig))=  CONJG(eigrb(ig,isa  )*dqgbt(ig,1)) &
     &                        + ci*      CONJG(eigrb(ig,isa+1)*dqgbt(ig,2))
                        END DO
                     ELSE
                        DO ig=1,ngb
                           qv(npb(ig)) =       eigrb(ig,isa)*dqgbt(ig,1)
                           qv(nmb(ig)) = CONJG(eigrb(ig,isa)*dqgbt(ig,1))
                        END DO
                     ENDIF
                     !
                     CALL invfft( 'Box', qv, dfftb, isa )
                     !
                     !  qv = US contribution in real space on box grid
                     !       for atomic species is, real(qv)=atom ia, imag(qv)=atom ia+1
                     !
                     !  add qv(r) to v(r), in real space on the dense grid
                     !
                     CALL box2grid( irb(1,isa), 1, qv, v )
                     IF (nfft.EQ.2) CALL box2grid(irb(1,isa+1),2,qv,v)

                     isa = isa + nfft
!
                  END DO
               END DO

               DEALLOCATE( dqgbt )
               DEALLOCATE( qv )
!
!$omp end parallel

               iss = 1

               DO ir=1,nnr
                  drhor(ir,iss,i,j) = drhor(ir,iss,i,j) + DBLE(v(ir))
               END DO
!
               CALL fwfft( 'Dense', v, dfftp )
!
               DO ig=1,ng
                  drhog(ig,iss,i,j) = drhog(ig,iss,i,j) + v(np(ig))
               END DO
!
            ENDDO
         ENDDO
!
      ELSE
         !
         !     nspin=2: two fft at a time, one for spin up and one for spin down
         ! 
         isup=1
         isdw=2
         DO i=1,3
            DO j=1,3
               v(:) = (0.d0, 0.d0)
               ALLOCATE( qv( nnrb ) )
               ALLOCATE( dqgbt( ngb, 2 ) )
               isa=1
               DO is=1,nvb
                  DO ia=1,na(is)
#ifdef __PARA
                     IF ( dfftb%np3( isa ) <= 0 ) go to 25
#endif
                     DO iss=1,2
                        dqgbt(:,iss) = (0.d0, 0.d0)
                        DO iv= 1,nh(is)
                           DO jv=iv,nh(is)
                              ijv = (jv-1)*jv/2 + iv
                              asumt=rhovan(ijv,isa,iss)
                              dsumt =drhovan(ijv,isa,iss,i,j)
                              IF(iv.NE.jv) THEN
                                 asumt =2.d0*asumt
                                 dsumt=2.d0*dsumt
                              ENDIF
                              DO ig=1,ngb
                                 dqgbt(ig,iss)=dqgbt(ig,iss)  +         &
     &                               (asumt*dqgb(ig,ijv,is,i,j) +         &
     &                               dsumt*qgb(ig,ijv,is))
                              END DO
                           END DO
                        END DO
                     END DO
                     !     
                     ! add structure factor
                     !
                     qv(:) = (0.d0, 0.d0)
                     DO ig=1,ngb
                        qv(npb(ig))= eigrb(ig,isa)*dqgbt(ig,1)        &
     &                    + ci*      eigrb(ig,isa)*dqgbt(ig,2)
                        qv(nmb(ig))= CONJG(eigrb(ig,isa)*dqgbt(ig,1)) &
     &                    +       ci*CONJG(eigrb(ig,isa)*dqgbt(ig,2))
                     END DO

                     CALL invfft('Box',qv, dfftb, isa )
                     !
                     !  qv is the now the US augmentation charge for atomic species is
                     !  and atom ia: real(qv)=spin up, imag(qv)=spin down
                     !
                     !  add qv(r) to v(r), in real space on the dense grid
                     !
                     CALL box2grid2(irb(1,isa),qv,v)
                     !
  25                 isa = isa + 1
                     !
                  END DO
               END DO

               DEALLOCATE( dqgbt )
               DEALLOCATE( qv )
!
               DO ir=1,nnr
                  drhor(ir,isup,i,j) = drhor(ir,isup,i,j) + DBLE(v(ir))
                  drhor(ir,isdw,i,j) = drhor(ir,isdw,i,j) +AIMAG(v(ir))
               ENDDO

!
               CALL fwfft('Dense', v, dfftp )

               DO ig=1,ng
                  fp=v(np(ig))+v(nm(ig))
                  fm=v(np(ig))-v(nm(ig))
                  drhog(ig,isup,i,j) = drhog(ig,isup,i,j) +             &
     &                 0.5d0*CMPLX( DBLE(fp),AIMAG(fm),kind=DP)
                  drhog(ig,isdw,i,j) = drhog(ig,isdw,i,j) +             &
     &                 0.5d0*CMPLX(AIMAG(fp),-DBLE(fm),kind=DP)
               END DO
!
            END DO
         END DO
      ENDIF


      DEALLOCATE( v )
!
      RETURN
END SUBROUTINE drhov

!
!-----------------------------------------------------------------------
SUBROUTINE rhov(irb,eigrb,rhovan,rhog,rhor)
!-----------------------------------------------------------------------
!     Add Vanderbilt contribution to rho(r) and rho(g)
!
!        n_v(g) = sum_i,ij rho_i,ij q_i,ji(g) e^-ig.r_i
!
!     routine makes use of c(-g)=c*(g)  and  beta(-g)=beta*(g)
!
      USE kinds,                    ONLY: dp
      USE ions_base,                ONLY: nat, na, nsp
      USE io_global,                ONLY: stdout
      USE mp_global,                ONLY: intra_image_comm
      USE mp,                       ONLY: mp_sum
      USE cvan,                     ONLY: nvb
      USE uspp_param,               ONLY: nh, nhm
      USE uspp,                     ONLY: deeq
      USE grid_dimensions,          ONLY: nr1, nr2, nr3, nr1x, nr2x, nr3x, nnr => nrxx
      USE electrons_base,           ONLY: nspin
      USE gvecb,                    ONLY: npb, nmb, ngb
      USE gvecp,                    ONLY: ng => ngm
      USE cell_base,                ONLY: omega, ainv
      USE small_box,                ONLY: omegab
      USE smallbox_grid_dimensions, ONLY: nr1b, nr2b, nr3b, nr1bx, nr2bx, nr3bx, nnrb => nnrbx
      USE control_flags,            ONLY: iprint, iprsta, tpre
      USE qgb_mod,                  ONLY: qgb
      USE recvecs_indexes,          ONLY: np, nm
      USE fft_interfaces,           ONLY: fwfft, invfft
      USE fft_base,                 ONLY: dfftb, dfftp
!
      IMPLICIT NONE
      !
      REAL(DP),    INTENT(IN) ::  rhovan(nhm*(nhm+1)/2,nat,nspin)
      INTEGER,     INTENT(in) :: irb(3,nat)
      COMPLEX(DP), INTENT(in):: eigrb(ngb,nat)
      ! 
      REAL(DP),     INTENT(inout):: rhor(nnr,nspin)
      COMPLEX(DP),  INTENT(inout):: rhog(ng,nspin)
!
      INTEGER     :: isup, isdw, nfft, ifft, iv, jv, ig, ijv, is, iss, isa, ia, ir, i, j
      REAL(DP)    :: sumrho
      COMPLEX(DP) :: ci, fp, fm, ca
      COMPLEX(DP), ALLOCATABLE :: qgbt(:,:)
      COMPLEX(DP), ALLOCATABLE :: v(:)
      COMPLEX(DP), ALLOCATABLE :: qv(:)

#ifdef __OPENMP
      INTEGER  :: itid, mytid, ntids
      INTEGER  :: omp_get_thread_num, omp_get_num_threads
      EXTERNAL :: omp_get_thread_num, omp_get_num_threads
#endif

      !  Quick return if this sub is not needed
      !
      IF ( nvb == 0 ) RETURN

      CALL start_clock( 'rhov' )
      ci=(0.d0,1.d0)
!
!
      ALLOCATE( v( nnr ) )

      ! private variable need to be initialized, otherwise
      ! outside the parallel region they have an undetermined value
      !
#ifdef __OPENMP
      mytid = 0
      ntids = 1
      itid  = 0
#endif
      iss   = 1
      isa   = 1
!
      IF(nspin.EQ.1) THEN
         ! 
         !     nspin=1 : two fft at a time, one per atom, if possible
         !

!$omp parallel default(none) &
!$omp          shared(nvb, na, nnrb, ngb, nh, rhovan, qgb, eigrb, dfftb, iprsta, omegab, irb, v, nr1b, &
!$omp                 nr2b, nr3b, nmb, stdout, ci, npb, rhor ) &
!$omp          private(mytid, ntids, is, ia, nfft, ifft, iv, jv, ijv, sumrho, qgbt, ig, iss, isa, ca, &
!$omp                  qv, itid, ir, nnr )

         iss=1
         isa=1

!$omp workshare
         v (:) = (0.d0, 0.d0)
!$omp end workshare

#ifdef __OPENMP
         mytid = omp_get_thread_num()  ! take the thread ID
         ntids = omp_get_num_threads() ! take the number of threads
         itid  = 0
#endif

         ALLOCATE( qgbt( ngb, 2 ) )
         ALLOCATE( qv( nnrb ) )


         DO is = 1, nvb

#ifdef __PARA

            DO ia = 1, na(is)
               nfft = 1
               IF ( dfftb%np3( isa ) <= 0 ) THEN
                  isa = isa + nfft
                  CYCLE
               END IF

#else

            DO ia = 1, na(is), 2
               !
               !  nfft=2 if two ffts at the same time are performed
               !
               nfft = 2
               IF( ia .EQ. na(is) ) nfft = 1
#endif

#ifdef __OPENMP
               IF ( mytid /= itid ) THEN
                  isa = isa + nfft
                  itid = MOD( itid + 1, ntids )
                  CYCLE
               ELSE
                  itid = MOD( itid + 1, ntids )
               END IF
#endif
               DO ifft=1,nfft
                  qgbt(:,ifft) = (0.d0, 0.d0)
                  DO iv= 1,nh(is)
                     DO jv=iv,nh(is)
                        ijv = (jv-1)*jv/2 + iv
                        sumrho=rhovan(ijv,isa+ifft-1,iss)
                        IF(iv.NE.jv) sumrho=2.d0*sumrho
                        DO ig=1,ngb
                           qgbt(ig,ifft)=qgbt(ig,ifft) + sumrho*qgb(ig,ijv,is)
                        END DO
                     END DO
                  END DO
               END DO
               !
               ! add structure factor
               !
               qv(:) = (0.d0, 0.d0)
               IF(nfft.EQ.2)THEN
                  DO ig=1,ngb
                     qv(npb(ig))=  &
                                   eigrb(ig,isa  )*qgbt(ig,1)  &
                        + ci*      eigrb(ig,isa+1)*qgbt(ig,2)
                     qv(nmb(ig))=                                       &
                             CONJG(eigrb(ig,isa  )*qgbt(ig,1))        &
                        + ci*CONJG(eigrb(ig,isa+1)*qgbt(ig,2))
                  END DO
               ELSE
                  DO ig=1,ngb
                     qv(npb(ig)) = eigrb(ig,isa)*qgbt(ig,1)
                     qv(nmb(ig)) = CONJG(eigrb(ig,isa)*qgbt(ig,1))
                  END DO
               ENDIF


               CALL invfft( 'Box', qv, dfftb, isa )
               !
               !  qv = US augmentation charge in real space on box grid
               !       for atomic species is, real(qv)=atom ia, imag(qv)=atom ia+1
 
               IF(iprsta.GT.2) THEN
                  ca = SUM(qv)
                  WRITE( stdout,'(a,f12.8)') ' rhov: 1-atom g-sp = ',         &
     &                 omegab*DBLE(qgbt(1,1))
                  WRITE( stdout,'(a,f12.8)') ' rhov: 1-atom r-sp = ',         &
     &                 omegab*DBLE(ca)/(nr1b*nr2b*nr3b)
                  WRITE( stdout,'(a,f12.8)') ' rhov: 1-atom g-sp = ',         &
     &                 omegab*DBLE(qgbt(1,2))
                  WRITE( stdout,'(a,f12.8)') ' rhov: 1-atom r-sp = ',         &
     &                 omegab*AIMAG(ca)/(nr1b*nr2b*nr3b)
               ENDIF
               !
               !  add qv(r) to v(r), in real space on the dense grid
               !
               CALL  box2grid(irb(1,isa),1,qv,v)
               IF (nfft.EQ.2) CALL  box2grid(irb(1,isa+1),2,qv,v)

               isa = isa + nfft
!
            END DO
         END DO

         DEALLOCATE(qv)
         DEALLOCATE(qgbt)
         !
         !  rhor(r) = total (smooth + US) charge density in real space
         !
!$omp end parallel

         iss = 1

         DO ir=1,nnr
            rhor(ir,iss)=rhor(ir,iss)+DBLE(v(ir))        
         END DO

!
         IF(iprsta.GT.2) THEN
            ca = SUM(v)

            CALL mp_sum( ca, intra_image_comm )

            WRITE( stdout,'(a,2f12.8)')                                  &
     &           ' rhov: int  n_v(r)  dr = ',omega*ca/(nr1*nr2*nr3)
         ENDIF
!
         CALL fwfft('Dense',v, dfftp )
!
         IF(iprsta.GT.2) THEN
            WRITE( stdout,*) ' rhov: smooth ',omega*rhog(1,iss)
            WRITE( stdout,*) ' rhov: vander ',omega*v(1)
            WRITE( stdout,*) ' rhov: all    ',omega*(rhog(1,iss)+v(1))
         ENDIF
         !
         !  rhog(g) = total (smooth + US) charge density in G-space
         !
         DO ig = 1, ng
            rhog(ig,iss)=rhog(ig,iss)+v(np(ig))
         END DO

!
         IF(iprsta.GT.2) WRITE( stdout,'(a,2f12.8)')                          &
     &        ' rhov: n_v(g=0) = ',omega*DBLE(rhog(1,iss))
!
      ELSE
         !
         !     nspin=2: two fft at a time, one for spin up and one for spin down
         !
         isup=1
         isdw=2

         v (:) = (0.d0, 0.d0)

         ALLOCATE( qgbt( ngb, 2 ) )
         ALLOCATE( qv( nnrb ) )

         isa=1
         DO is=1,nvb
            DO ia=1,na(is)
#ifdef __PARA
               IF ( dfftb%np3( isa ) <= 0 ) go to 25
#endif
               DO iss=1,2
                  qgbt(:,iss) = (0.d0, 0.d0)
                  DO iv=1,nh(is)
                     DO jv=iv,nh(is)
                        ijv = (jv-1)*jv/2 + iv
                        sumrho=rhovan(ijv,isa,iss)
                        IF(iv.NE.jv) sumrho=2.d0*sumrho
                        DO ig=1,ngb
                           qgbt(ig,iss)=qgbt(ig,iss)+sumrho*qgb(ig,ijv,is)
                        END DO
                     END DO
                  END DO
               END DO
!     
! add structure factor
!
               qv(:) = (0.d0, 0.d0)
               DO ig=1,ngb
                  qv(npb(ig)) =    eigrb(ig,isa)*qgbt(ig,1)           &
     &                  + ci*      eigrb(ig,isa)*qgbt(ig,2)
                  qv(nmb(ig)) = CONJG(eigrb(ig,isa)*qgbt(ig,1))       &
     &                  + ci*   CONJG(eigrb(ig,isa)*qgbt(ig,2))
               END DO
!
               CALL invfft('Box',qv,dfftb,isa)
!
!  qv is the now the US augmentation charge for atomic species is
!  and atom ia: real(qv)=spin up, imag(qv)=spin down
!
               IF(iprsta.GT.2) THEN
                  ca = SUM(qv)
                  WRITE( stdout,'(a,f12.8)') ' rhov: up   g-space = ',        &
     &                 omegab*DBLE(qgbt(1,1))
                  WRITE( stdout,'(a,f12.8)') ' rhov: up r-sp = ',             &
     &                 omegab*DBLE(ca)/(nr1b*nr2b*nr3b)
                  WRITE( stdout,'(a,f12.8)') ' rhov: dw g-space = ',          &
     &                 omegab*DBLE(qgbt(1,2))
                  WRITE( stdout,'(a,f12.8)') ' rhov: dw r-sp = ',             &
     &                 omegab*AIMAG(ca)/(nr1b*nr2b*nr3b)
               ENDIF
!
!  add qv(r) to v(r), in real space on the dense grid
!
               CALL box2grid2(irb(1,isa),qv,v)
  25           isa=isa+1
!
            END DO
         END DO
!
         DO ir=1,nnr
            rhor(ir,isup)=rhor(ir,isup)+DBLE(v(ir)) 
            rhor(ir,isdw)=rhor(ir,isdw)+AIMAG(v(ir)) 
         END DO
!
         IF(iprsta.GT.2) THEN
            ca = SUM(v)
            CALL mp_sum( ca, intra_image_comm )
            WRITE( stdout,'(a,2f12.8)') 'rhov:in n_v  ',omega*ca/(nr1*nr2*nr3)
         ENDIF
!
         CALL fwfft('Dense',v, dfftp )
!
         IF(iprsta.GT.2) THEN
            WRITE( stdout,*) 'rhov: smooth up',omega*rhog(1,isup)
            WRITE( stdout,*) 'rhov: smooth dw',omega*rhog(1,isdw)
            WRITE( stdout,*) 'rhov: vander up',omega*DBLE(v(1))
            WRITE( stdout,*) 'rhov: vander dw',omega*AIMAG(v(1))
            WRITE( stdout,*) 'rhov: all up',                                  &
     &           omega*(rhog(1,isup)+DBLE(v(1)))
            WRITE( stdout,*) 'rhov: all dw',                                  &
     &           omega*(rhog(1,isdw)+AIMAG(v(1)))
         ENDIF
!
         DO ig=1,ng
            fp=  v(np(ig)) + v(nm(ig))
            fm=  v(np(ig)) - v(nm(ig))
            rhog(ig,isup)=rhog(ig,isup) + 0.5d0*CMPLX(DBLE(fp),AIMAG(fm),kind=DP)
            rhog(ig,isdw)=rhog(ig,isdw) + 0.5d0*CMPLX(AIMAG(fp),-DBLE(fm),kind=DP)
         END DO

!
         IF(iprsta.GT.2) WRITE( stdout,'(a,2f12.8)')                          &
     &        ' rhov: n_v(g=0) up   = ',omega*DBLE (rhog(1,isup))
         IF(iprsta.GT.2) WRITE( stdout,'(a,2f12.8)')                          &
     &        ' rhov: n_v(g=0) down = ',omega*DBLE(rhog(1,isdw))

         DEALLOCATE(qgbt)
         DEALLOCATE( qv )
!
      ENDIF

      DEALLOCATE( v )

      CALL stop_clock( 'rhov' )
!
      RETURN
END SUBROUTINE rhov
!
!
!
!----------------------------------------------------------------------
    SUBROUTINE read_rho( nspin, rhor )
!----------------------------------------------------------------------
      !
      ! read rhor(nnr,nspin) from file
      !
      use kinds,           ONLY: DP
      USE fft_base,        ONLY: dfftp
      use grid_dimensions, ONLY: nr1, nr2, nr3, nr1x, nr2x, nrxx
      use xml_io_base,     ONLY: read_rho_xml, restart_dir
      use control_flags,   ONLY: ndr
      USE io_files,        ONLY: tmp_dir
      !
      implicit none
      !
      integer  :: nspin
      real(DP) :: rhor( nrxx, nspin )
      !
      integer            :: is
      CHARACTER(LEN=256) :: filename, dirname
      !
      dirname = restart_dir( tmp_dir, ndr )
      !
      filename = TRIM(dirname) // '/' // 'charge-density'
      !
      CALL read_rho_xml( filename, rhor(:,1), nr1, nr2, nr3, nr1x, nr2x, dfftp%ipp, dfftp%npp )
      !
      IF( nspin == 2 ) THEN
         !
         filename = TRIM(dirname) // '/' // 'spin-polarization'
         !
         CALL read_rho_xml( filename, rhor(:,2), nr1, nr2, nr3, nr1x, nr2x, dfftp%ipp, dfftp%npp )
         !
         !  Convert rho_tot, spin_pol back to rho_up, rho_down
         !
         rhor(:,2) = 0.5d0 * ( rhor(:,1) - rhor(:,2) )
         rhor(:,1) = rhor(:,1) - rhor(:,2)
         !
      END IF

      RETURN
    END SUBROUTINE read_rho
!
!----------------------------------------------------------------------
      subroutine old_write_rho( rhounit, nspin, rhor, a1, a2, a3 )
!----------------------------------------------------------------------
!
! collect rhor(nrxx,nspin) on first node and write to file
!
      use kinds,           ONLY: DP
      use parallel_include
      use grid_dimensions, only : nr1x, nr2x, nr3x, nrxx
      use gvecw ,          only : ngw
      USE mp_global,       ONLY : nproc_image, intra_image_comm
      USE io_global,       ONLY : ionode, ionode_id
      USE fft_base,        ONLY : dfftp
      USE mp,              ONLY : mp_barrier, mp_gather
      USE constants,       ONLY : bohr_radius_angs
      !
      implicit none
      !
      integer,       INTENT(IN) :: rhounit, nspin
      real(kind=DP), INTENT(IN) :: rhor( nrxx, nspin )
      real(kind=DP), INTENT(IN) :: a1(3), a2(3), a3(3)
      !
      integer :: ir, is

      integer :: proc, ierr
      integer, allocatable:: displs(:), recvcount(:)
      real(kind=DP), allocatable:: rhodist(:)
      !     
      IF ( ionode ) THEN
         ! 
         OPEN( unit = rhounit, form = 'UNFORMATTED', status = 'UNKNOWN' )
         !
         WRITE( rhounit, '("3  2")' )
         ! 
         WRITE( rhounit, '(3(2X,I3))' ) nr1x, nr2x, nr3x
         !  
         WRITE( rhounit, '(3(2X,"0",2X,F16.10))' ) &
             ( DBLE( nr1x - 1 ) / DBLE( nr1x ) ) * a1(1) * bohr_radius_angs, &
             ( DBLE( nr2x - 1 ) / DBLE( nr2x ) ) * a2(2) * bohr_radius_angs, &
             ( DBLE( nr3x - 1 ) / DBLE( nr3x ) ) * a3(3) * bohr_radius_angs
         !  
      END IF
      !
      COLLECT_CHARGE: IF( nproc_image > 1 ) THEN
         !
         ALLOCATE( displs( nproc_image ), recvcount( nproc_image ) )
         !
         if (ionode) allocate(rhodist(nr1x*nr2x*nr3x))
         !
         do proc=1,nproc_image
            recvcount(proc) =  dfftp%nnp  * ( dfftp%npp(proc) )
            if (proc.eq.1) then
               displs(proc)=0
            else
               displs(proc)=displs(proc-1) + recvcount(proc-1)
            end if
         end do
         !
         do is=1,nspin
            !
            ! gather the charge density on the first node
            !
            call mp_barrier()
            call mp_gather( rhor(:,is), rhodist, recvcount, displs, ionode_id, intra_image_comm )
            !
            ! write the charge density to unit "rhounit" from first node only
            !
            if ( ionode ) &
               write( rhounit, '(F12.7)' ) (rhodist(ir),ir=1,nr1x*nr2x*nr3x)
            !
         end do
      
         DEALLOCATE( displs, recvcount )
         if (ionode) deallocate(rhodist)

      ELSE

         IF ( ionode ) THEN
            WRITE( rhounit, '(F12.7)' ) ( ( rhor(ir,is), ir = 1, nrxx ), is = 1, nspin )
         END IF

      END IF COLLECT_CHARGE

      IF ( ionode ) THEN
         CLOSE( unit = rhounit )
      END IF
      !
      return
      end subroutine old_write_rho


