import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import APPLICATION_INTAKE from '@salesforce/schema/Application_Intake__c';
import SOURCE_RECORD_KEY from '@salesforce/schema/Application_Intake__c.Source_Record_Key__c';
import EMPLOYER_NAME from '@salesforce/schema/Application_Intake__c.Employer_Name__c';
import JOB_TITLE from '@salesforce/schema/Application_Intake__c.Job_Title__c';
import SOURCE_STAGE from '@salesforce/schema/Application_Intake__c.Source_Stage__c';
import APPLIED_DATE from '@salesforce/schema/Application_Intake__c.Applied_Date__c';
import getQueue from '@salesforce/apex/CareerHubApplicationIntake.getQueue';
import review from '@salesforce/apex/CareerHubApplicationIntake.review';

export default class CareerHubIntakeQueue extends LightningElement {
    intakeObject = APPLICATION_INTAKE;
    sourceRecordKey = SOURCE_RECORD_KEY;
    employerName = EMPLOYER_NAME;
    jobTitle = JOB_TITLE;
    appliedDate = APPLIED_DATE;
    sourceStage = SOURCE_STAGE;
    showCompleted = false;
    rows = [];
    queueError;
    actionError;
    queueWire;
    selectedId;
    employerId;
    busy = false;

    @wire(getQueue, { showCompleted: '$showCompleted' })
    wiredQueue(result) {
        this.queueWire = result;
        if (result.data) {
            this.rows = result.data.map((row) => ({
                ...row,
                applicationUrl: row.Job_Application__c
                    ? '/lightning/r/Job_Application__c/' + row.Job_Application__c + '/view'
                    : null
            }));
            this.queueError = undefined;
        } else if (result.error) {
            this.rows = [];
            this.queueError = this.message(result.error);
        }
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get selectedRow() {
        return this.rows.find((row) => row.Id === this.selectedId);
    }

    get sourceNeedsCorrection() {
        const row = this.selectedRow;
        return row && (!row.Applied_Date__c || row.Source_Stage__c !== 'Applied');
    }

    async handleStaged() {
        const form = this.template.querySelector('[data-stage-form]');
        if (form) form.querySelectorAll('lightning-input-field').forEach((field) => field.reset());
        this.showCompleted = false;
        this.toast('Confirmation staged', 'It is ready for review.', 'success');
        await this.refreshQueue();
    }

    async handleSourceSaved() {
        this.toast('Source details saved', 'Review this confirmation again when ready.', 'success');
        await this.refreshQueue();
    }

    handleToggle(event) {
        this.selectedId = undefined;
        this.employerId = undefined;
        this.actionError = undefined;
        this.rows = [];
        this.showCompleted = event.target.checked;
    }

    handleSelect(event) {
        this.selectedId = event.currentTarget.dataset.id;
        this.employerId = undefined;
        this.actionError = undefined;
    }

    handleEmployer(event) {
        this.employerId = event.detail.recordId;
    }

    async handleReview() {
        if (this.busy || !this.selectedRow) return;
        this.busy = true;
        this.actionError = undefined;
        try {
            const status = await review({
                intakeId: this.selectedId,
                employerId: this.employerId || null
            });
            if (status === 'Needs Review') {
                this.toast('Needs review', 'See the review detail for the next step.', 'warning');
            } else {
                this.toast(status, 'Find the linked application under completed items.', 'success');
                this.selectedId = undefined;
                this.employerId = undefined;
            }
            await this.refreshQueue();
        } catch (error) {
            this.actionError = this.message(error);
        } finally {
            this.busy = false;
        }
    }

    async refreshQueue() {
        try {
            if (this.queueWire) await refreshApex(this.queueWire);
        } catch (error) {
            this.queueError = this.message(error);
        }
    }

    message(error) {
        return error?.body?.message || error?.message || 'An unexpected error occurred.';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
